#!/usr/bin/env bats

# T6 — raft snapshot save/restore for the local OpenBao. Integration test
# against a disposable scratch copy (scratch state dir, spare port), same
# pattern as bootstrap.bats — never the real daemon or state dir. All
# secrets are 0600 files (ADR 0011) — no keychain, no fnox.
#
# Proves the two documented restore paths in environments/local/README.md:
#   1. restore into the running daemon rolls a change back (auto-unseal)
#   2. `-force` restore into a fresh instance recovers the original
#      approval-key — given the snapshot's own seal.key + root.token
#      (the bundle `mise run local:openbao:snapshot` writes together)

setup() {
  load helper
  SCRATCH="$(mktemp -d)"
  scratch_copy "$SCRATCH" "environments/local"
  rm -rf "$SCRATCH/environments/local/.terraform" \
    "$SCRATCH/environments/local/.terraform.lock.hcl" \
    "$SCRATCH/environments/local/openbao/.terraform" \
    "$SCRATCH/environments/local/scripts/tests"

  local port; port="$(free_port)"
  export TOOLBOX_OPENBAO_STATE_DIR="$SCRATCH/state"
  export TOOLBOX_OPENBAO_DAEMON="openbao-bats-snap-$$"
  export TOOLBOX_OPENBAO_LISTEN="127.0.0.1:$port"
  export TOOLBOX_OPENBAO_SUPERVISOR="none"
  export TOOLBOX_OPENBAO_RESET_YES=1
  export VAULT_ADDR="http://127.0.0.1:$port"
  SNAP="$TOOLBOX_OPENBAO_STATE_DIR/snapshots/latest.snap"

  cd "$SCRATCH" || return 1
}

teardown() {
  load helper
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid" ] &&
    kill "$(cat "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid")" 2>/dev/null || true
  pkill -f "bao server -config=$TOOLBOX_OPENBAO_STATE_DIR" 2>/dev/null || true
  cd /
  rm -rf "$SCRATCH"
}

# bootstrap (static seal auto-unseals) + echo the root token
_bootstrap() {
  ./environments/local/scripts/openbao-bootstrap.sh >/dev/null 2>&1
  cat "$TOOLBOX_OPENBAO_STATE_DIR/root.token"
}

# The bundle `mise run local:openbao:snapshot` writes: snap + seal.key + root.token.
_snapshot_bundle() {
  ./environments/local/scripts/openbao-snapshot.sh >/dev/null
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

@test "openbao-snapshot writes a complete bundle: snap + seal.key + root.token" {
  VAULT_TOKEN="$(_bootstrap)"
  export VAULT_TOKEN
  [ -d "$TOOLBOX_OPENBAO_STATE_DIR/snapshots" ]
  run _snapshot_bundle
  [ "$status" -eq 0 ]
  [ -s "$SNAP" ]
  [ -s "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/seal.key" ]
  [ -s "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/root.token" ]
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

@test "disaster: -force restore into a fresh instance from the snapshots/ bundle recovers the original key" {
  orig_token="$(_bootstrap)"
  export VAULT_TOKEN="$orig_token"
  before="$(_pubkey)"
  _snapshot_bundle                                     # snap + seal.key + root.token in snapshots/

  ./environments/local/scripts/openbao-reset.sh
  [ -d "$TOOLBOX_OPENBAO_STATE_DIR/snapshots" ]        # reset kept the bundle

  fresh_token="$(_bootstrap)"
  export VAULT_TOKEN="$fresh_token"
  [ "$(_pubkey)" != "$before" ]                        # genuinely a new instance

  run bao operator raft snapshot restore -force "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/latest.snap"
  [ "$status" -eq 0 ]
  # The restored data is sealed by the bundle's ORIGINAL seal.key -> put it
  # back and restart; auth with the bundle's ORIGINAL root.token.
  cp -f "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/seal.key" "$TOOLBOX_OPENBAO_STATE_DIR/seal.key"
  _restart_daemon
  _assert_unsealed
  export VAULT_TOKEN="$(cat "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/root.token")"
  [ "$(_pubkey)" = "$before" ]
}
