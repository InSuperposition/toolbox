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
  cd /
  rm -rf "$SCRATCH"
}

# bootstrap + echo "<unseal-key> <root-token>"
_bootstrap() {
  local out unseal token
  out="$(./scripts/bootstrap-openbao.sh 2>&1)"
  unseal="$(printf '%s\n' "$out" | grep -A1 'UNSEAL KEY' | tail -1 | tr -d '[:space:]')"
  token="$(fnox get VAULT_TOKEN)"
  printf '%s %s\n' "$unseal" "$token"
}

_unseal_if_needed() {
  if ! bao status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null 2>&1; then
    bao operator unseal "$1" >/dev/null
  fi
}

_pubkey() { cosign public-key --key openbao://approval-key 2>/dev/null; }

@test "the module creates the snapshot directory so the save works on a fresh checkout" {
  _bootstrap >/dev/null
  [ -d "$TOOLBOX_OPENBAO_STATE_DIR/snapshots" ]
  VAULT_TOKEN="$(fnox get VAULT_TOKEN)"
  export VAULT_TOKEN
  run bao operator raft snapshot save "$SNAP"
  [ "$status" -eq 0 ]
  [ -s "$SNAP" ]
}

@test "restore into the running daemon rolls a key rotation back" {
  read -r unseal token < <(_bootstrap)
  export VAULT_TOKEN="$token"

  before="$(_pubkey)"
  [ -n "$before" ]
  bao operator raft snapshot save "$SNAP"

  bao write -f transit/keys/approval-key/rotate >/dev/null
  rotated="$(_pubkey)"
  [ "$rotated" != "$before" ]

  run bao operator raft snapshot restore -force "$SNAP"
  [ "$status" -eq 0 ]
  _unseal_if_needed "$unseal"

  [ "$(_pubkey)" = "$before" ]
}

@test "-force restore into a fresh instance recovers the original approval-key" {
  read -r unseal token < <(_bootstrap)
  export VAULT_TOKEN="$token"
  before="$(_pubkey)"
  bao operator raft snapshot save "$SNAP"
  cp "$SNAP" "$BATS_TEST_TMPDIR/saved.snap"

  run ./scripts/reset-openbao.sh
  [ "$status" -eq 0 ]
  [ -d "$TOOLBOX_OPENBAO_STATE_DIR/snapshots" ]   # reset kept snapshots/

  read -r _ fresh_token < <(_bootstrap)
  export VAULT_TOKEN="$fresh_token"
  [ "$(_pubkey)" != "$before" ]

  run bao operator raft snapshot restore -force "$BATS_TEST_TMPDIR/saved.snap"
  [ "$status" -eq 0 ]
  _unseal_if_needed "$unseal"
  export VAULT_TOKEN="$token"

  [ "$(_pubkey)" = "$before" ]
}
