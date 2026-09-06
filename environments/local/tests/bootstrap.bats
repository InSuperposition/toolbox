#!/usr/bin/env bats

# Integration test for the machine-global OpenBao bootstrap flow
# (scripts/bootstrap-openbao.sh + bao server). Runs against a disposable
# scratch copy of the repo's OpenBao-relevant files, a scratch state dir
# and a spare port -- so it never touches ~/.local/state/toolbox/openbao/
# or the real keychain entry.
#
# Most tests use TOOLBOX_OPENBAO_SUPERVISOR=none (a plain tracked bg
# process) to keep the real ~/.config/pitchfork/config.toml untouched; one
# test exercises the real `pitchfork daemons add --global` path.
#
# Covers the flow that hid real bugs during development: raft's missing
# auto-created data dir, the render-config / provision-transit
# chicken-and-egg ordering, and reset leaving stale Terraform state.

setup() {
  SCRATCH="$(mktemp -d)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  mkdir -p "$SCRATCH/environments"
  cp -r "$REPO_ROOT/environments/local" "$SCRATCH/environments/local"
  rm -rf "$SCRATCH/environments/local/.terraform" "$SCRATCH/environments/local/tests"
  cp -r "$REPO_ROOT/modules" "$SCRATCH/modules"
  cp -r "$REPO_ROOT/scripts" "$SCRATCH/scripts"

  export TOOLBOX_OPENBAO_STATE_DIR="$SCRATCH/state"
  export TOOLBOX_OPENBAO_DAEMON="openbao-bats-$$"
  export TOOLBOX_OPENBAO_LISTEN="127.0.0.1:8399"
  export TOOLBOX_OPENBAO_KEYCHAIN_SERVICE="toolbox-openbao-bats-test"
  export TOOLBOX_OPENBAO_SUPERVISOR="none"
  export TOOLBOX_OPENBAO_RESET_YES=1
  export VAULT_ADDR="http://127.0.0.1:8399"

  # Scratch fnox service + explicit account name (the keychain provider
  # needs `value` to resolve the entry -- see fnox.toml's own comment).
  cat > "$SCRATCH/fnox.toml" <<'EOF'
[providers.keychain]
type = "keychain"
service = "toolbox-openbao-bats-test"

[secrets]
VAULT_TOKEN = { provider = "keychain", value = "VAULT_TOKEN" }
EOF

  cd "$SCRATCH"
}

teardown() {
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid" ] &&
    kill "$(cat "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid")" 2>/dev/null || true
  pkill -f "bao server -config=$TOOLBOX_OPENBAO_STATE_DIR" 2>/dev/null || true
  pitchfork stop "global/$TOOLBOX_OPENBAO_DAEMON" 2>/dev/null || true
  pitchfork daemons remove --global "$TOOLBOX_OPENBAO_DAEMON" 2>/dev/null || true
  security delete-generic-password -s toolbox-openbao-bats-test -a VAULT_TOKEN >/dev/null 2>&1 || true
  cd /
  rm -rf "$SCRATCH"
}

@test "bootstrap renders config + creates the raft data dir despite the expected first-apply auth error" {
  run ./scripts/bootstrap-openbao.sh
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/openbao.hcl" ]
  [ -d "$TOOLBOX_OPENBAO_STATE_DIR/data" ]
}

@test "full bootstrap: init, unseal, apply, verify raft + transit" {
  ./scripts/bootstrap-openbao.sh

  run bao status
  [[ "$output" == *"raft"* ]]

  export VAULT_TOKEN
  VAULT_TOKEN="$(fnox get VAULT_TOKEN)"
  run bao secrets list
  [[ "$output" == *"transit/"* ]]
}

@test "re-running the bootstrap script after init is a clean no-op, not a re-init attempt" {
  ./scripts/bootstrap-openbao.sh
  run ./scripts/bootstrap-openbao.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already initialized"* ]]
}

@test "reset does NOT rewrite fnox.toml (F7), then re-bootstrap starts fresh" {
  ./scripts/bootstrap-openbao.sh
  before="$(cat "$SCRATCH/fnox.toml")"

  run ./scripts/reset-openbao.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/fnox.toml")" = "$before" ]   # [secrets] declaration intact

  run ./scripts/bootstrap-openbao.sh
  [ "$status" -eq 0 ]
  run bash -c "bao status -format=json | jq -e '.initialized == true'"
  [ "$status" -eq 0 ]
}

@test "bootstrap registers + starts a machine-global pitchfork daemon" {
  export TOOLBOX_OPENBAO_SUPERVISOR="pitchfork"
  ./scripts/bootstrap-openbao.sh
  run pitchfork list
  [[ "$output" == *"$TOOLBOX_OPENBAO_DAEMON"* ]]
  [[ "$output" == *"running"* ]]
}
