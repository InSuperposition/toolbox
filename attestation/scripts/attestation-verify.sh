#!/usr/bin/env bash
set -euo pipefail

# The consumer-side gate — and the one shared seam every consumer goes
# through (docs/designs/digest-as-source-of-truth.md § Architecture; ADR
# 0013): the local demo's `mise run frontend:deploy`, the frontend daemon's
# launch re-verify, and T10's VEX check all call this. Given an image digest
# and the digest of a specific approval attestation, it answers one
# question: is THIS attestation a valid "approved" decision, signed by the
# approval key, for THIS image?
#
#   attestation-verify.sh <registry/repo@sha256:<image>> <sha256:<attestation>>
#
# It NEVER touches OpenBao (Codex P1-7). Verification is against the
# committed public key (attestation/cosign-approval.pub), exported once from
# openbao://approval-key at bootstrap. Losing the OpenBao raft store stops
# future signing but does not invalidate past approvals.
#
# Selection model: the caller pins ONE attestation by digest. A signed
# "rejected" record, or a bad-signature record, sitting on the same image is
# irrelevant — only the pinned attestation is looked at.
#
# Exit 0  — valid, signed by the approval key, verdict "approved".
# Exit 1  — TERMINAL verification failure, distinct stderr line: bad
#           signature / wrong subject / wrong predicate type / verdict
#           rejected / bad schema. Re-running will not change the answer.
# Exit 2  — bad arguments / missing public key.
# Exit 3  — RETRYABLE: the attestation or its bundle blob could not be
#           pulled (not found yet / registry unreachable / rate-limited).
#           The frontend daemon retries this with backoff; a human re-runs it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null  # lib is exercised via attestation-verify.bats
. "$SCRIPT_DIR/lib/attestation.sh"

TYPE="$ATTESTATION_TYPE"
BUNDLE_ARTIFACT_TYPE="application/vnd.dev.sigstore.bundle.v0.3+json"

POLICY="$SCRIPT_DIR/../verdict-approved.cue"
PUBKEY="${TOOLBOX_APPROVAL_PUBKEY:-$SCRIPT_DIR/../cosign-approval.pub}"

fail() { echo "attestation-verify: $1" >&2; exit 1; }
retryable() { echo "attestation-verify: $1" >&2; exit 3; }

if [ $# -ne 2 ]; then
	echo "usage: attestation-verify.sh <registry/repo@sha256:<image>> <sha256:<attestation-digest>>" >&2
	exit 2
fi
IMAGE_REF="$1"
ATT_DIGEST="$2"

attestation_is_digest_ref "$IMAGE_REF" \
	|| { echo "attestation-verify: '$IMAGE_REF' is not a full digest reference (a tag is not accepted)" >&2; exit 2; }
printf '%s' "$ATT_DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$' \
	|| { echo "attestation-verify: '$ATT_DIGEST' is not a sha256 digest" >&2; exit 2; }
[ -f "$PUBKEY" ] || { echo "attestation-verify: approval public key not found at $PUBKEY" >&2; exit 2; }

REPO="${IMAGE_REF%@*}"
IMAGE_HEX="${IMAGE_REF##*@sha256:}"
REGISTRY_HOST="${REPO%%/*}"
ORAS_HTTP=()
if attestation_is_local_registry "$REGISTRY_HOST"; then ORAS_HTTP=(--plain-http); fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- 1. Pull the pinned attestation (by its own digest). A fetch failure
#        here is retryable — the digest may be right but the registry is
#        unreachable / the referrer not propagated yet. ---
if ! att_manifest="$(oras manifest fetch "${ORAS_HTTP[@]}" "${REPO}@${ATT_DIGEST}" 2>"$WORKDIR/err")"; then
	retryable "could not fetch attestation $ATT_DIGEST from $REPO: $(head -1 "$WORKDIR/err")"
fi

art_type="$(printf '%s' "$att_manifest" | jq -r '.artifactType // .config.artifactType // empty')"
[ "$art_type" = "$BUNDLE_ARTIFACT_TYPE" ] \
	|| fail "$ATT_DIGEST is not a cosign attestation (artifactType: ${art_type:-none})"

layer_digest="$(printf '%s' "$att_manifest" | jq -r '.layers[0].digest')"
if ! oras blob fetch "${ORAS_HTTP[@]}" --output "$WORKDIR/bundle.json" "${REPO}@${layer_digest}" 2>"$WORKDIR/err"; then
	retryable "could not fetch attestation bundle blob from $REPO: $(head -1 "$WORKDIR/err")"
fi

# --- 2. Signature + subject + predicate-type, in one cosign call ---
if ! cosign verify-blob-attestation \
	--bundle "$WORKDIR/bundle.json" \
	--key "$PUBKEY" \
	--type "$TYPE" \
	--check-claims \
	--digest "$IMAGE_HEX" \
	--digestAlg sha256 \
	--insecure-ignore-tlog \
	>/dev/null 2>"$WORKDIR/verify.err"; then
	err="$(cat "$WORKDIR/verify.err")"
	case "$err" in
	*"invalid predicate type"*) fail "wrong predicate type — this attestation is not an approval record" ;;
	*"does not match any digest in statement"*) fail "wrong subject — this attestation is for a different image" ;;
	*"accepted signatures do not match threshold"* | *"could not verify envelope"* | *"signature"*)
		fail "bad signature — not signed by the approval key ($PUBKEY)" ;;
	*) fail "attestation verification failed: ${err%%$'\n'*}" ;;
	esac
fi

# --- 3. Verdict must be "approved" (the poison-proof check) ---
jq -r '.dsseEnvelope.payload' "$WORKDIR/bundle.json" | base64 -d >"$WORKDIR/statement.json"
if ! cue vet "$WORKDIR/statement.json" -d '#ApprovedStatement' "$POLICY" 2>"$WORKDIR/cue.err"; then
	verdict="$(jq -r '.predicate.verdict // "unknown"' "$WORKDIR/statement.json")"
	if [ "$verdict" = "rejected" ]; then
		reason="$(jq -r '.predicate.reason // ""' "$WORKDIR/statement.json")"
		fail "verdict: rejected${reason:+ — $reason}"
	fi
	fail "attestation does not satisfy the approval schema (verdict: $verdict)"
fi
