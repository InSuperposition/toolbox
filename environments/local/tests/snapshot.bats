#!/usr/bin/env bats

# T6 — raft snapshot save/restore for the local OpenBao. Integration test
# against a disposable scratch copy (never the real environments/local/ or
# the real keychain), same pattern as bootstrap.bats.
#
# The scratch instance runs on a spare port (127.0.0.1:8399), so it does
# NOT disturb the real :8200 daemon — unlike bootstrap.bats, this suite is
# safe to run with your OpenBao up.
#
# Proves the two documented restore paths in environments/local/README.md:
#   1. restore into the running daemon rolls back a change
#   2. `-force` restore into a freshly bootstrapped instance recovers the
#      original approval-key (verified by cosign against openbao://) —
#      given the original unseal key + root token

SNAP="environments/local/openbao/snapshots/latest.snap"

setup() {
  SCRATCH="$(mktemp -d)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  mkdir -p "$SCRATCH/environments"
  cp -r "$REPO_ROOT/environments/local" "$SCRATCH/environments/local"
  # a real bootstrap leaves runtime state in environments/local/ — scratch
  # must start pristine or `tofu apply` operates on state for resources that
  # don't exist in the fresh scratch OpenBao.
  rm -rf "$SCRATCH/environments/local/openbao" \
    "$SCRATCH/environments/local/.terraform" \
    "$SCRATCH/environments/local/.terraform.lock.hcl" \
    "$SCRATCH/environments/local/tests"
  rm -f "$SCRATCH"/environments/local/terraform.tfstate*
  cp -r "$REPO_ROOT/modules" "$SCRATCH/modules"
  cp -r "$REPO_ROOT/scripts" "$SCRATCH/scripts"

  # Spare port — the real daemon owns :8200/:8201. The module renders
  # openbao.hcl (listener + api_addr) from these, and bootstrap-openbao.sh
  # honours a pre-set VAULT_ADDR.
  cat > "$SCRATCH/environments/local/main.tf" <<'EOF'
module "secret_openbao_local" {
  source              = "../../modules/secret-openbao-local"
  transit_keys        = [{ name = "approval-key", type = "ecdsa-p256" }]
  openbao_config_path = "openbao/openbao.hcl"
  listener_address    = "127.0.0.1:8399"
  cluster_address     = "127.0.0.1:8398"
}
EOF
  # point the vault provider at the scratch port too (auto-loaded)
  echo 'openbao_addr = "http://127.0.0.1:8399"' > "$SCRATCH/environments/local/terraform.tfvars"
  cat > "$SCRATCH/pitchfork.toml" <<'EOF'
[daemons.openbao]
run = "bao server -config=openbao/openbao.hcl"
dir = "environments/local"
retry = 0
ready_delay = 2
ready_port = 8399
EOF

  cat > "$SCRATCH/fnox.toml" <<'EOF'
[providers.keychain]
type = "keychain"
service = "toolbox-openbao-bats-test"

[secrets]
VAULT_TOKEN = { provider = "keychain", value = "VAULT_TOKEN" }
EOF

  export VAULT_ADDR=http://127.0.0.1:8399
  cd "$SCRATCH" || return 1
}

teardown() {
  pitchfork stop openbao 2>/dev/null || true
  pitchfork daemons remove openbao 2>/dev/null || true
  fnox remove VAULT_TOKEN 2>/dev/null || true
  cd /
  rm -rf "$SCRATCH"
}

# bootstrap + echo "<unseal-key> <root-token>" (both captured from output / fnox)
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
  [ -d environments/local/openbao/snapshots ]
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
  [ "$rotated" != "$before" ]   # sanity: rotation moved the exported key

  run bao operator raft snapshot restore -force "$SNAP"
  [ "$status" -eq 0 ]
  _unseal_if_needed "$unseal"

  [ "$(_pubkey)" = "$before" ]  # rolled back to the snapshot's key version
}

@test "-force restore into a fresh instance recovers the original approval-key" {
  read -r unseal token < <(_bootstrap)
  export VAULT_TOKEN="$token"
  before="$(_pubkey)"
  bao operator raft snapshot save "$SNAP"
  cp "$SNAP" "$BATS_TEST_TMPDIR/saved.snap"

  run ./scripts/reset-openbao.sh
  [ "$status" -eq 0 ]
  [ -f "$SNAP" ] || [ -d environments/local/openbao/snapshots ]   # reset kept snapshots/

  read -r _ fresh_token < <(_bootstrap)
  export VAULT_TOKEN="$fresh_token"
  [ "$(_pubkey)" != "$before" ]   # genuinely a different instance/key now

  run bao operator raft snapshot restore -force "$BATS_TEST_TMPDIR/saved.snap"
  [ "$status" -eq 0 ]
  _unseal_if_needed "$unseal"          # ORIGINAL unseal key
  export VAULT_TOKEN="$token"          # ORIGINAL root token

  [ "$(_pubkey)" = "$before" ]         # original key is back and readable via openbao://
}
