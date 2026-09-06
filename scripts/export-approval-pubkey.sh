#!/usr/bin/env bash
set -euo pipefail

# Export the PUBLIC half of openbao://approval-key to
# deploy/frontend/cosign-approval.pub and commit that file. The consume
# side (verify-approval.sh / `mise run consume`) verifies a pinned approval
# attestation against this committed key and never calls OpenBao (Codex
# P1-7), so a raft-store loss stops future signing but leaves every past
# approval verifiable.
#
# Run this at bootstrap and AGAIN after any Transit key rotation -- the
# exported public key changes on rotation, and consume would otherwise
# verify new signatures against a stale key.
#
# Needs OpenBao up + unsealed and VAULT_ADDR / VAULT_TOKEN set (fnox
# activate, or the bootstrap sets them).

cd "$(dirname "$0")/.."

: "${VAULT_ADDR:=http://127.0.0.1:8200}"
export VAULT_ADDR
: "${VAULT_TOKEN:=$(fnox get VAULT_TOKEN 2>/dev/null || true)}"
export VAULT_TOKEN

OUT="deploy/frontend/cosign-approval.pub"
mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# cosign 3.1.3 resolves openbao:// and hashivault:// to the same KMS
# plugin; try the repo's canonical scheme first, then the alias.
if cosign public-key --key "openbao://approval-key" --outfile "$TMP" 2>/dev/null; then
	:
elif cosign public-key --key "hashivault://approval-key" --outfile "$TMP" 2>/dev/null; then
	:
else
	# Last resort: read the key's public material straight from Transit.
	bao read -format=json transit/keys/approval-key \
		| jq -r '.data.keys | to_entries | max_by(.key | tonumber) | .value.public_key' >"$TMP"
fi

grep -q "BEGIN PUBLIC KEY" "$TMP" || {
	echo "export-approval-pubkey: did not get a PEM public key" >&2
	exit 1
}

if [ -f "$OUT" ] && cmp -s "$TMP" "$OUT"; then
	echo "unchanged: $OUT"
else
	mv "$TMP" "$OUT"
	trap - EXIT
	echo "wrote $OUT -- commit it:  git add $OUT"
fi
