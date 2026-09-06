#!/usr/bin/env bash
set -euo pipefail

# One-time OpenBao bootstrap: renders config, starts the daemon, inits +
# unseals, provisions Transit, stores the root token in fnox. Replaces a
# manual multi-step sequence. Idempotent: safe to re-run once initialized.
#
# The unseal key is printed once and NEVER stored by this script or fnox
# -- keeping it out-of-band is the point (CLAUDE.md Zero Trust section).
# Only the root token (fnox's actual steady-state job) gets automated.

cd "$(dirname "$0")/.."

echo "==> Rendering OpenBao config (a Transit auth error here is expected)"
(cd environments/local && tofu init -input=false && tofu apply -auto-approve) || true
test -f environments/local/openbao/openbao.hcl || {
  echo "config render failed -- environments/local/openbao/openbao.hcl was not created" >&2
  exit 1
}

echo "==> Starting OpenBao via pitchfork"
# No -f: force-restarting an already-running, already-leader raft instance
# briefly disrupts it (observed: "cannot find peer" / "Raft RPC layer
# closed" during re-election) and can make the very next `bao status`
# check below transiently wrong. Idempotent runs should leave an
# already-running daemon alone, not restart it every time.
pitchfork start openbao

export VAULT_ADDR=http://127.0.0.1:8200

if bao status -format=json 2>/dev/null | jq -e '.initialized == true' >/dev/null 2>&1; then
  echo "==> Already initialized -- run scripts/reset-openbao.sh first if you meant to start fresh"
else
  echo "==> Initializing (single Shamir share -- solo dev daemon, not a production ceremony)"
  init_json=$(bao operator init -key-shares=1 -key-threshold=1 -format=json)
  unseal_key=$(echo "$init_json" | jq -r '.unseal_keys_b64[0]')
  root_token=$(echo "$init_json" | jq -r '.root_token')

  bao operator unseal "$unseal_key" >/dev/null
  echo "$root_token" | fnox set VAULT_TOKEN --provider keychain
  export VAULT_TOKEN="$root_token"

  echo "==> UNSEAL KEY -- store this out-of-band NOW (a password manager, not this repo):"
  echo "    $unseal_key"
  echo "==> Root token stored via fnox. Future sessions: eval \$(fnox activate zsh)"
fi

echo "==> Provisioning Transit engine + keys"
(cd environments/local && tofu apply -auto-approve)

# Export the approval key's PUBLIC half into the repo. verify-approval.sh /
# `mise run consume` verify a pinned approval attestation against THIS file
# and never call OpenBao (Codex P1-7) -- so a raft-store loss stops future
# signing but leaves every past approval verifiable. Re-run this bootstrap
# (or re-export) and re-commit the file after any Transit key rotation, or
# consume verifies new signatures against a stale key.
echo "==> Exporting approval public key -> deploy/frontend/cosign-approval.pub"
: "${VAULT_TOKEN:=$(fnox get VAULT_TOKEN 2>/dev/null || true)}"
export VAULT_TOKEN
./scripts/export-approval-pubkey.sh || {
  echo "    WARNING: pubkey export failed -- OpenBao itself is fine." >&2
  echo "    Re-run: mise run export-approval-pubkey   (before mise run consume)" >&2
}

bao secrets list
bao status
