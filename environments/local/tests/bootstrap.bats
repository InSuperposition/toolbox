#!/usr/bin/env bats

# Integration test for the OpenBao bootstrap flow (pitchfork + bao server +
# scripts/bootstrap-openbao.sh). Runs against a disposable scratch copy of
# the repo's OpenBao-relevant files, never the real environments/local/.
# Covers the flow that hid 3 real bugs during development: raft's missing
# auto-created data dir, the render-config/provision-transit
# chicken-and-egg ordering, and reset-openbao.sh leaving stale Terraform
# state that skipped recreating the data-dir placeholder on rebootstrap.

setup() {
  SCRATCH="$(mktemp -d)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  mkdir -p "$SCRATCH/environments"
  cp -r "$REPO_ROOT/environments/local" "$SCRATCH/environments/local"
  rm -rf "$SCRATCH/environments/local/openbao" "$SCRATCH/environments/local/.terraform" "$SCRATCH/environments/local/tests"
  cp -r "$REPO_ROOT/modules" "$SCRATCH/modules"
  cp "$REPO_ROOT/pitchfork.toml" "$SCRATCH/pitchfork.toml"
  cp -r "$REPO_ROOT/scripts" "$SCRATCH/scripts"

  # Distinct fnox service so this test never touches the real
  # toolbox-openbao keychain entry.
  cat > "$SCRATCH/fnox.toml" <<'EOF'
[providers.keychain]
type = "keychain"
service = "toolbox-openbao-bats-test"

[secrets]
VAULT_TOKEN = { provider = "keychain" }
EOF

  cd "$SCRATCH"
}

teardown() {
  pitchfork stop openbao 2>/dev/null || true
  pitchfork daemons remove openbao 2>/dev/null || true
  fnox remove VAULT_TOKEN 2>/dev/null || true
  cd /
  rm -rf "$SCRATCH"
}

@test "bootstrap script renders config and creates the raft data dir despite the expected first-apply auth error" {
  run ./scripts/bootstrap-openbao.sh
  # First apply is expected to hit "no vault token set" before pitchfork
  # even starts, then bootstrap continues -- overall exit code depends on
  # whether OpenBao ends up initialized; assert the artifacts unconditionally.
  [ -f environments/local/openbao/openbao.hcl ]
  [ -d environments/local/openbao/data ]
}

@test "pitchfork starts the daemon from repo-root cwd (not from inside environments/local/)" {
  ./scripts/bootstrap-openbao.sh || true
  run pitchfork status openbao
  [[ "$output" == *"running"* ]]
}

@test "full bootstrap: init, unseal, apply, verify raft + transit" {
  ./scripts/bootstrap-openbao.sh
  export VAULT_ADDR=http://127.0.0.1:8200

  run bao status
  [[ "$output" == *"raft"* ]]

  # bao secrets list is authenticated -- the bootstrap script's own
  # `export VAULT_TOKEN` doesn't survive past its own subprocess, so
  # retrieve it the same way any other consumer would: via fnox.
  export VAULT_TOKEN
  VAULT_TOKEN="$(fnox get VAULT_TOKEN)"
  run bao secrets list
  [[ "$output" == *"transit/"* ]]
}

@test "re-running the bootstrap script after init is a clean no-op, not a re-init attempt" {
  ./scripts/bootstrap-openbao.sh || true
  run ./scripts/bootstrap-openbao.sh
  [[ "$output" == *"Already initialized"* ]]
}

@test "reset followed by re-bootstrap starts fully fresh, not stuck on stale Terraform state" {
  ./scripts/bootstrap-openbao.sh
  run ./scripts/reset-openbao.sh
  [ "$status" -eq 0 ]

  run ./scripts/bootstrap-openbao.sh
  export VAULT_ADDR=http://127.0.0.1:8200
  run bao status
  [[ "$output" == *"raft"* ]]

  # Same check the script itself uses (jq, not a fragile string match --
  # bao's JSON key spacing isn't part of any stable contract).
  run bash -c "bao status -format=json | jq -e '.initialized == true'"
  [ "$status" -eq 0 ]
}
