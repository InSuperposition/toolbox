#!/usr/bin/env bats

# T6 — raft snapshot save/restore for the local OpenBao. Integration test
# against a disposable scratch copy (scratch state dir, uniquely-named
# global daemon, spare port), same pattern as bootstrap.bats — never the
# real `openbao` daemon, ~/.local/state/toolbox/openbao/ or the real
# keychain.
#
# Proves the two documented restore paths in environments/local/README.md:
#   1. restore into the running daemon rolls a change back
#   2. `-force` restore into a freshly bootstrapped instance recovers the
#      original approval-key (verified by cosign against openbao://) —
#      given the original unseal key + root token

setup() {
  SCRATCH="$(mktemp -d)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  mkdir -p "$SCRATCH/environments"
  cp -r "$REPO_ROOT/environments/local" "$SCRATCH/environments/local"
  rm -rf "$SCRATCH/environments/local/.terraform" \
    "$SCRATCH/environments/local/.terraform.lock.hcl" \
    "$SCRATCH/environments/local/tests"
  cp -r "$REPO_ROOT/modules" "$SCRATCH/modules"
  cp -r "$REPO_ROOT/scripts" "$SCRATCH/scripts"

  export TOOLBOX_OPENBAO_STATE_DIR="$SCRATCH/state"
  export TOOLBOX_OPENBAO_DAEMON="openbao-bats-snap-$$"
  export TOOLBOX_OPENBAO_LISTEN="127.0.0.1:8398"
  export TOOLBOX_OPENBAO_KEYCHAIN_SERVICE="toolbox-openbao-bats-test"
  export TOOLBOX_OPENBAO_SUPERVISOR="none"
  export TOOLBOX_OPENBAO_RESET_YES=1
  export VAULT_ADDR="http://127.0.0.1:8398"
  SNAP="$TOOLBOX_OPENBAO_STATE_DIR/snapshots/latest.snap"

  cat > "$SCRATCH/fnox.toml" <<'EOF'
[providers.keychain]
type = "keychain"
service = "toolbox-openbao-bats-test"

[secrets]
VAULT_TOKEN = { provider = "keychain", value = "VAULT_TOKEN" }
EOF

  cd "$SCRATCH" || return 1
}

teardown() {
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid" ] &&
    kill "$(cat "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid")" 2>/dev/null || true
  pkill -f "bao server -config=$TOOLBOX_OPENBAO_STATE_DIR" 2>/dev/null || true
  security delete-generic-password -s toolbox-openbao-bats-test -a VAULT_TOKEN >/dev/null 2>&1 || true
  security delete-generic-password -s toolbox-openbao-bats-test -a BAO_RECOVERY_KEY >/dev/null 2>&1 || true
  cd /
  rm -rf "$SCRATCH"
}

# bootstrap (static seal auto-unseals) + echo the root token
_bootstrap() {
  ./scripts/bootstrap-openbao.sh >/dev/null 2>&1
  fnox get VAULT_TOKEN
}

# Static seal: the daemon auto-unseals on every start AND after a restore
# (same seal.key). If it is ever still sealed here, that is a real bug to
# surface, not paper over.
_assert_unsealed() {
  bao status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null
}

_pubkey() { cosign public-key --key openbao://approval-key 2>/dev/null; }

_restart_daemon() {
  local pid
  pid="$(cat "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  # Wait for the process to actually exit and release the raft bolt lock,
  # otherwise the new one dies with "failed to open bolt file: timeout".
  for _ in $(seq 1 50); do
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  bao server -config="$TOOLBOX_OPENBAO_STATE_DIR/openbao.hcl" \
    >"$TOOLBOX_OPENBAO_STATE_DIR/bao.log" 2>&1 &
  echo $! >"$TOOLBOX_OPENBAO_STATE_DIR/bao.pid"
  # Poll for auto-unseal directly (up to ~20s) rather than the health
  # endpoint -- a -force restore can take a few seconds to settle.
  for _ in $(seq 1 100); do
    bao status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "daemon did not auto-unseal after restart:" >&2
  tail -20 "$TOOLBOX_OPENBAO_STATE_DIR/bao.log" >&2
  return 1
}

@test "the module creates the snapshot directory so the save works on a fresh checkout" {
  VAULT_TOKEN="$(_bootstrap)"
  export VAULT_TOKEN
  [ -d "$TOOLBOX_OPENBAO_STATE_DIR/snapshots" ]
  run bao operator raft snapshot save "$SNAP"
  [ "$status" -eq 0 ]
  [ -s "$SNAP" ]
}

@test "restore into the running daemon rolls a key rotation back, auto-unsealed" {
  VAULT_TOKEN="$(_bootstrap)"
  export VAULT_TOKEN

  before="$(_pubkey)"
  [ -n "$before" ]
  bao operator raft snapshot save "$SNAP"

  bao write -f transit/keys/approval-key/rotate >/dev/null
  [ "$(_pubkey)" != "$before" ]

  run bao operator raft snapshot restore -force "$SNAP"
  [ "$status" -eq 0 ]
  _assert_unsealed                       # same seal.key -> no manual step
  [ "$(_pubkey)" = "$before" ]
}

@test "-force restore into a fresh instance recovers the original key (given the original seal.key + token)" {
  orig_token="$(_bootstrap)"
  export VAULT_TOKEN="$orig_token"
  before="$(_pubkey)"
  bao operator raft snapshot save "$SNAP"
  cp "$SNAP" "$BATS_TEST_TMPDIR/saved.snap"
  # The three things kept together for a disaster restore (README.md):
  # the snapshot, its own seal.key, its own root token.
  cp "$TOOLBOX_OPENBAO_STATE_DIR/seal.key" "$BATS_TEST_TMPDIR/saved.key"

  ./scripts/reset-openbao.sh
  [ -d "$TOOLBOX_OPENBAO_STATE_DIR/snapshots" ]        # reset kept snapshots/

  fresh_token="$(_bootstrap)"
  export VAULT_TOKEN="$fresh_token"
  [ "$(_pubkey)" != "$before" ]                        # genuinely a new instance

  run bao operator raft snapshot restore -force "$BATS_TEST_TMPDIR/saved.snap"
  [ "$status" -eq 0 ]
  # The restored data is sealed by the ORIGINAL key -> put it back, restart.
  cp "$BATS_TEST_TMPDIR/saved.key" "$TOOLBOX_OPENBAO_STATE_DIR/seal.key"
  _restart_daemon
  _assert_unsealed
  export VAULT_TOKEN="$orig_token"                     # ORIGINAL root token
  [ "$(_pubkey)" = "$before" ]
}
