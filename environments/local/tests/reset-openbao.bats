#!/usr/bin/env bats

# Focused unit-ish coverage for scripts/reset-openbao.sh. The bootstrap +
# snapshot suites exercise reset transitively; this pins its specific
# contract: the confirm gate, what it wipes vs keeps, and F7 (it must NOT
# rewrite fnox.toml).

setup() {
  SCRATCH="$(mktemp -d)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  cp -r "$REPO_ROOT/scripts" "$SCRATCH/scripts"

  export TOOLBOX_OPENBAO_STATE_DIR="$SCRATCH/state"
  export TOOLBOX_OPENBAO_DAEMON="openbao-bats-reset-$$"
  export TOOLBOX_OPENBAO_SUPERVISOR="none"
  export TOOLBOX_OPENBAO_KEYCHAIN_SERVICE="toolbox-openbao-bats-test"

  mkdir -p "$TOOLBOX_OPENBAO_STATE_DIR/data" "$TOOLBOX_OPENBAO_STATE_DIR/snapshots"
  : > "$TOOLBOX_OPENBAO_STATE_DIR/openbao.hcl"
  : > "$TOOLBOX_OPENBAO_STATE_DIR/seal.key"
  : > "$TOOLBOX_OPENBAO_STATE_DIR/tofu.tfstate"
  echo keep > "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/latest.snap"

  cd "$SCRATCH"
}

teardown() {
  security delete-generic-password -s toolbox-openbao-bats-test -a VAULT_TOKEN >/dev/null 2>&1 || true
  cd /
  rm -rf "$SCRATCH"
}

@test "no confirmation and no TOOLBOX_OPENBAO_RESET_YES -> aborts, wipes nothing" {
  run bash -c 'printf "n\n" | ./scripts/reset-openbao.sh'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted."* ]]
  [ -d "$TOOLBOX_OPENBAO_STATE_DIR/data" ]
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/seal.key" ]
}

@test "confirmed reset wipes data/config/seal.key/tfstate, keeps snapshots/" {
  export TOOLBOX_OPENBAO_RESET_YES=1
  run ./scripts/reset-openbao.sh
  [ "$status" -eq 0 ]
  [ ! -e "$TOOLBOX_OPENBAO_STATE_DIR/data" ]
  [ ! -e "$TOOLBOX_OPENBAO_STATE_DIR/openbao.hcl" ]
  [ ! -e "$TOOLBOX_OPENBAO_STATE_DIR/seal.key" ]
  [ ! -e "$TOOLBOX_OPENBAO_STATE_DIR/tofu.tfstate" ]
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/latest.snap" ]   # kept
}

@test "reset does not touch the repo's fnox.toml (F7)" {
  cp "$REPO_ROOT/fnox.toml" "$SCRATCH/fnox.toml"
  before="$(cat "$SCRATCH/fnox.toml")"
  export TOOLBOX_OPENBAO_RESET_YES=1
  ./scripts/reset-openbao.sh
  [ "$(cat "$SCRATCH/fnox.toml")" = "$before" ]
}

@test "reset clears the keychain items directly (security), not via fnox remove" {
  security add-generic-password -U -s toolbox-openbao-bats-test -a VAULT_TOKEN -w dummy
  export TOOLBOX_OPENBAO_RESET_YES=1
  ./scripts/reset-openbao.sh
  run security find-generic-password -s toolbox-openbao-bats-test -a VAULT_TOKEN
  [ "$status" -ne 0 ]
}
