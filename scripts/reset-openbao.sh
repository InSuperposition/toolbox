#!/usr/bin/env bash
set -euo pipefail

# Wipes local OpenBao's raft data AND its fnox-held root token together,
# so a re-bootstrap never leaves one stale relative to the other -- a
# shell with fnox already activated could otherwise keep injecting a
# root token from a previous, now-wiped OpenBao instance.

cd "$(dirname "$0")/.."

pitchfork stop openbao 2>/dev/null || true
rm -rf environments/local/openbao
fnox remove VAULT_TOKEN 2>/dev/null || true

# Also clear Terraform's own state, not just the data directory -- without
# this, tofu sees no drift for local_file.openbao_data_dir_keep (its state
# still says the file exists) and never recreates it, so the next bootstrap
# fails with "failed to open bolt file: ... no such file or directory".
# A reset means start fully fresh, not just wipe the data on disk.
rm -f environments/local/terraform.tfstate environments/local/terraform.tfstate.backup

echo "Cleared. Run: mise run openbao-bootstrap"
