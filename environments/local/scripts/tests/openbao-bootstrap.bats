#!/usr/bin/env bats

# Integration test for the machine-global OpenBao bootstrap flow
# (environments/local/scripts/openbao-bootstrap.sh + bao server). Runs
# against a disposable scratch copy of environments/local, a scratch state
# dir and a spare port -- so it never touches ~/.local/state/toolbox/openbao/.
#
# All secrets are 0600 files under the scratch state dir (ADR 0011): no
# keychain, no fnox -- so the suite never triggers a keychain prompt.
#
# Most tests use TOOLBOX_OPENBAO_SUPERVISOR=none (a plain tracked bg
# process) to keep the real ~/.config/pitchfork/config.toml untouched; one
# test exercises the real `pitchfork daemons add --global` path.

setup() {
  load helper
  SCRATCH="$(mktemp -d)"
  # the whole environments/local concern — its scripts, the ./openbao tofu
  # unit, main.tf.
  scratch_copy "$SCRATCH" "environments/local"
  rm -rf "$SCRATCH/environments/local/.terraform" \
         "$SCRATCH/environments/local/openbao/.terraform" \
         "$SCRATCH/environments/local/scripts/tests"
  # openbao-bootstrap.sh calls `mise run attestation:export-pubkey`; there
  # is no repo mise.toml above the scratch, so stub it (records the call +
  # runs the real export against the scratch OpenBao into $SCRATCH/attestation).
  fake_mise_export "$SCRATCH/attestation"

  # a free port per test, not a fixed one — two `mise run check` in
  # separate worktrees must not fight over the listener.
  local port; port="$(free_port)"
  export TOOLBOX_OPENBAO_STATE_DIR="$SCRATCH/state"
  export TOOLBOX_OPENBAO_DAEMON="openbao-bats-$$"
  export TOOLBOX_OPENBAO_LISTEN="127.0.0.1:$port"
  export TOOLBOX_OPENBAO_SUPERVISOR="none"
  export TOOLBOX_OPENBAO_RESET_YES=1
  export VAULT_ADDR="http://127.0.0.1:$port"

  cd "$SCRATCH" || return 1
}

teardown() {
  load helper
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid" ] &&
    kill "$(cat "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid")" 2>/dev/null || true
  pkill -f "bao server -config=$TOOLBOX_OPENBAO_STATE_DIR" 2>/dev/null || true
  # scoped to THIS test's daemon only — never a machine-wide `pitchfork
  # clean`, which would nuke a concurrent run's daemon (CX #7). --daemon
  # also clears the stopped entry `daemons remove` leaves in `pitchfork list`.
  pitchfork stop "global/$TOOLBOX_OPENBAO_DAEMON" 2>/dev/null || true
  pitchfork daemons remove --global "$TOOLBOX_OPENBAO_DAEMON" 2>/dev/null || true
  pitchfork clean --daemon "global/$TOOLBOX_OPENBAO_DAEMON" 2>/dev/null || true
  cd /
  rm -rf "$SCRATCH"
}

@test "bootstrap renders config + creates the raft data dir despite the expected first-apply auth error" {
  run ./environments/local/scripts/openbao-bootstrap.sh
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/openbao.hcl" ]
  [ -d "$TOOLBOX_OPENBAO_STATE_DIR/data" ]
}

@test "full bootstrap: init, auto-unseal, apply, verify raft + transit + secret files" {
  run ./environments/local/scripts/openbao-bootstrap.sh
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNSEAL KEY"* ]]   # static seal — no unseal ceremony

  run bash -c "bao status -format=json | jq -e '.sealed == false and .initialized == true and .type == \"static\"'"
  [ "$status" -eq 0 ]
  run bao status
  [[ "$output" == *"raft"* ]]

  # secrets are 0600 files, not keychain
  for f in seal.key root.token recovery.key; do
    [ -s "$TOOLBOX_OPENBAO_STATE_DIR/$f" ]
    [ "$(file_mode "$TOOLBOX_OPENBAO_STATE_DIR/$f")" = "600" ]   # portable: GNU + BSD stat
  done

  export VAULT_TOKEN
  VAULT_TOKEN="$(cat "$TOOLBOX_OPENBAO_STATE_DIR/root.token")"
  run bao secrets list
  [[ "$output" == *"transit/"* ]]

  # bootstrap CALLED `mise run attestation:export-pubkey` (never wrote the
  # pubkey file itself — CX #3), and the task produced the key.
  [ -f "$SCRATCH/.mise-export-calls" ]
  run grep -q "BEGIN PUBLIC KEY" "$SCRATCH/attestation/cosign-approval.pub"
  [ "$status" -eq 0 ]
}

@test "bootstrap ignores an inherited VAULT_TOKEN — always uses its own root.token" {
  # Under `mise run check` a scratch bootstrap would otherwise carry the
  # real daemon's token and 403 against this instance's listener.
  VAULT_TOKEN="hvs.inherited-garbage-not-this-instance" run ./environments/local/scripts/openbao-bootstrap.sh
  [ "$status" -eq 0 ]
  export VAULT_TOKEN
  VAULT_TOKEN="$(cat "$TOOLBOX_OPENBAO_STATE_DIR/root.token")"
  run bao secrets list
  [[ "$output" == *"transit/"* ]]
}

@test "write_secret_file (lib/openbao.sh) replaces an existing 0644 file atomically at 0600" {
  # Redirecting into an existing file keeps its perms and follows symlinks,
  # so the extracted helper does mktemp+chmod+mv. Test the real lib, not a
  # copy.
  # the lib call runs in a fresh `bash -c` that sources only lib/openbao.sh —
  # file_mode (helper.bash) is not visible there, so assert the mode out
  # here in the bats shell against the now-written scratch-state file.
  run bash -euo pipefail -c '
    . "'"$SCRATCH"'/environments/local/scripts/lib/openbao.sh"
    d="'"$TOOLBOX_OPENBAO_STATE_DIR"'"; mkdir -p "$d"
    printf oldbad > "$d/k"; chmod 666 "$d/k"
    write_secret_file "$d/k" newval
    [ "$(cat "$d/k")" = newval ]
  '
  [ "$status" -eq 0 ]
  [ "$(file_mode "$TOOLBOX_OPENBAO_STATE_DIR/k")" = "600" ]
}

@test "the daemon auto-unseals on restart with no manual step" {
  ./environments/local/scripts/openbao-bootstrap.sh

  local pid
  pid="$(cat "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid")"
  kill "$pid"
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done

  bao server -config="$TOOLBOX_OPENBAO_STATE_DIR/openbao.hcl" \
    >"$TOOLBOX_OPENBAO_STATE_DIR/bao.log" 2>&1 &
  echo $! >"$TOOLBOX_OPENBAO_STATE_DIR/bao.pid"

  for _ in $(seq 1 100); do
    bao status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "did not auto-unseal:" >&2; tail -20 "$TOOLBOX_OPENBAO_STATE_DIR/bao.log" >&2
  return 1
}

@test "re-running the bootstrap script after init is a clean no-op, not a re-init attempt" {
  ./environments/local/scripts/openbao-bootstrap.sh
  run ./environments/local/scripts/openbao-bootstrap.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already initialized"* ]]
}

@test "an initialised bao whose root.token does not authenticate is rejected, not adopted" {
  # Stands in for a foreign 'bao server' / stale per-worktree daemon on
  # $LISTEN: the instance is up and initialised, but our root.token is not
  # its token. Bootstrap must stop before the 2nd tofu apply, not run it
  # against the wrong instance.
  ./environments/local/scripts/openbao-bootstrap.sh
  printf 'hvs.not-this-instances-token' >"$TOOLBOX_OPENBAO_STATE_DIR/root.token"

  run ./environments/local/scripts/openbao-bootstrap.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"not the toolbox daemon"* ]]
  [[ "$output" != *"Provisioning Transit"* ]]
}

@test "reset then re-bootstrap starts fully fresh" {
  ./environments/local/scripts/openbao-bootstrap.sh
  run ./environments/local/scripts/openbao-reset.sh
  [ "$status" -eq 0 ]
  [ ! -e "$TOOLBOX_OPENBAO_STATE_DIR/root.token" ]
  [ ! -e "$TOOLBOX_OPENBAO_STATE_DIR/seal.key" ]

  run ./environments/local/scripts/openbao-bootstrap.sh
  [ "$status" -eq 0 ]
  run bash -c "bao status -format=json | jq -e '.initialized == true'"
  [ "$status" -eq 0 ]
}

@test "bootstrap registers + starts a machine-global pitchfork daemon" {
  export TOOLBOX_OPENBAO_SUPERVISOR="pitchfork"
  ./environments/local/scripts/openbao-bootstrap.sh
  run pitchfork list
  [[ "$output" == *"$TOOLBOX_OPENBAO_DAEMON"* ]]
  [[ "$output" == *"running"* ]]
}
