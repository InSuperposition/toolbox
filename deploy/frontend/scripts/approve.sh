#!/usr/bin/env bash
set -euo pipefail

# The one place in the digest-as-source-of-truth pipeline with real logic:
# gather the build evidence, put it in front of a human, take their
# approve/reject decision, and sign it as an in-toto attestation over the
# image digest (docs/designs/digest-as-source-of-truth.md § T5).
#
#   mise run approve -- <registry/repo@sha256:...>
#
# Signs with openbao://approval-key (OpenBao Transit, key material never
# leaves OpenBao). ALWAYS writes a signed record — approve OR reject, never
# silent — EXCEPT when the operator aborts at the prompt (EOF / Ctrl-C /
# empty), which writes nothing.
#
# Selection model: this prints the new attestation's own digest. The
# consumer pins THAT digest — `mise run consume -- <ref> <attestation-digest>`
# — so a later reject, or a signed reject sitting next to this approval,
# does not change what an already-pinned consumer sees.
#
# Interim auth (full multi-member design is a separate planning session —
# TODOS.md "Auth + multi-member DX"): signing authenticates to OpenBao with
# the root token from fnox (VAULT_TOKEN); pushing to a non-local registry
# uses `gh auth token` at call time. Both are per-operator and call-time,
# no stored registry secret. approvedBy is therefore self-asserted.
#
# Exit codes: 0 ok · 1 operator aborted · 2 bad args · 3 OpenBao unavailable
# (openbao-preflight.sh) · 4 build evidence missing · 5 predicate failed its
# own schema · 6 signing / registry push failed.

TYPE="https://insuperposition.github.io/toolbox/attestations/approval/v1"
KEY_NAME="approval-key"
SBOM_ARTIFACT_TYPE="application/vnd.cyclonedx+json"
SCAN_ARTIFACT_TYPE="application/vnd.trivy.report+json"

# Signing key. The real value is openbao://approval-key (OpenBao Transit).
# TOOLBOX_APPROVE_KEY overrides it with a local cosign key file for the bats
# tests ONLY — a local key needs no OpenBao, so the preflight is skipped
# when the override is set. Never set this in real use.
SIGNING_KEY="${TOOLBOX_APPROVE_KEY:-openbao://$KEY_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$SCRIPT_DIR/../verdict-approved.cue"

usage() {
	echo "usage: mise run approve -- <registry/repo@sha256:<64 hex>>" >&2
	exit 2
}

[ $# -eq 1 ] || usage
IMAGE_REF="$1"

# Full digest reference only — a tag is mutable, which is the whole point of
# this pipeline. `repo:tag` and `repo` (no digest) are rejected here.
if ! printf '%s' "$IMAGE_REF" | grep -Eq '^[A-Za-z0-9.:_/-]+@sha256:[0-9a-f]{64}$'; then
	echo "approve: '$IMAGE_REF' is not a full digest reference" >&2
	echo "  need: registry/repo@sha256:<64 hex>   (a tag is not accepted — it is mutable)" >&2
	exit 2
fi

REPO="${IMAGE_REF%@*}"
IMAGE_DIGEST="${IMAGE_REF##*@}"
REGISTRY_HOST="${REPO%%/*}"

# Local dev registries speak http and need no auth; everything else is GHCR
# over https with a call-time `gh` token (interim auth).
ORAS_HTTP=()
case "$REGISTRY_HOST" in
127.0.0.1:* | localhost:* | 127.0.0.1 | localhost)
	ORAS_HTTP=(--plain-http)
	LOCAL_REGISTRY=1
	;;
*)
	LOCAL_REGISTRY=0
	;;
esac

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- 1. OpenBao must be able to sign before we waste the operator's time ---
if [ -z "${TOOLBOX_APPROVE_KEY:-}" ]; then
	"$SCRIPT_DIR/openbao-preflight.sh" "$KEY_NAME"
	: "${VAULT_ADDR:=http://127.0.0.1:8200}"
	export VAULT_ADDR
	export VAULT_TOKEN="${VAULT_TOKEN:?openbao-preflight passed but VAULT_TOKEN is unset}"
fi

# --- 2. Registry auth (interim: gh token, isolated docker config) ---
if [ "$LOCAL_REGISTRY" -eq 0 ]; then
	command -v gh >/dev/null || { echo "approve: gh not on PATH (interim registry auth)" >&2; exit 6; }
	export DOCKER_CONFIG="$WORKDIR/docker"
	mkdir -p "$DOCKER_CONFIG"
	GH_USER="$(gh api user --jq .login)"
	if ! gh auth token | cosign login "$REGISTRY_HOST" -u "$GH_USER" --password-stdin >/dev/null 2>&1; then
		echo "approve: could not log in to $REGISTRY_HOST with the gh token" >&2
		echo "  the token needs write:packages scope (and SSO authorised for the org)" >&2
		exit 6
	fi
fi

# --- 3. Gather the build evidence (SBOM + scan report referrers) ---
echo "==> Evidence for $IMAGE_REF"
referrers="$(oras discover "${ORAS_HTTP[@]}" --format json "$IMAGE_REF")"

find_referrer() {
	printf '%s' "$referrers" | jq -r --arg t "$1" \
		'[.referrers[] | select(.artifactType == $t)] | last | .reference // empty'
}
sbom_ref="$(find_referrer "$SBOM_ARTIFACT_TYPE")"
scan_ref="$(find_referrer "$SCAN_ARTIFACT_TYPE")"

missing=""
[ -n "$sbom_ref" ] || missing="CycloneDX SBOM ($SBOM_ARTIFACT_TYPE)"
[ -n "$scan_ref" ] || missing="${missing:+$missing, }trivy scan report ($SCAN_ARTIFACT_TYPE)"
if [ -n "$missing" ]; then
	echo "approve: build evidence missing on this digest: $missing" >&2
	echo "  run the T4 workflow (.github/workflows/build-cv-frontend.yml) for this SHA first" >&2
	exit 4
fi

SCAN_REPORT_REF="${scan_ref##*@}"

# The referrer's reference is a MANIFEST digest; the file itself is its
# single layer blob. Fetch the manifest, then the layer.
fetch_referrer_file() {
	local ref="$1" out="$2" repo="${1%@*}" mf blob
	mf="$(oras manifest fetch "${ORAS_HTTP[@]}" "$ref")"
	blob="$(printf '%s' "$mf" | jq -r '.layers[0].digest')"
	oras blob fetch "${ORAS_HTTP[@]}" --output "$out" "${repo}@${blob}"
}
fetch_referrer_file "$scan_ref" "$WORKDIR/scan.json"
fetch_referrer_file "$sbom_ref" "$WORKDIR/sbom.json"

echo "    SBOM:        $sbom_ref"
echo "    components:  $(jq '[.components[]?] | length' "$WORKDIR/sbom.json")"
echo "    scan report: $scan_ref"
jq -r '
  ([.Results[]?.Vulnerabilities[]?] // []) as $v
  | ($v | group_by(.Severity) | map("\(.[0].Severity)=\(length)") | join("  ")) as $bySev
  | "    findings:    " + (if ($v | length) == 0 then "none" else $bySev end)
' "$WORKDIR/scan.json"
echo "    (full report: jq . < $WORKDIR/scan.json  — kept until this script exits)"
echo

# --- 4. The human decision. EOF / Ctrl-C / empty => nothing is written. ---
abort() { echo; echo "approve: aborted — no attestation written." >&2; exit 1; }

verdict=""
read -r -p "verdict [approve / reject]: " answer || abort
case "$answer" in
approve | a) verdict="approved" ;;
reject | r) verdict="rejected" ;;
"") abort ;;
*) echo "approve: expected 'approve' or 'reject', got '$answer'" >&2; abort ;;
esac

read -r -p "reason (required): " reason || abort
[ -n "$reason" ] || { echo "approve: a reason is required for both verdicts" >&2; abort; }

APPROVED_BY="${TOOLBOX_APPROVED_BY:-$(gh api user --jq .login 2>/dev/null || echo "${USER:-unknown}")}"
APPROVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- 5. Build + schema-check the predicate before signing ---
jq -n \
	--arg digest "$IMAGE_DIGEST" \
	--arg verdict "$verdict" \
	--arg reason "$reason" \
	--arg approvedBy "$APPROVED_BY" \
	--arg approvedAt "$APPROVED_AT" \
	--arg scanReportRef "$SCAN_REPORT_REF" \
	'{schemaVersion: 1, digest: $digest, verdict: $verdict, reason: $reason,
	  approvedBy: $approvedBy, approvedAt: $approvedAt, scanReportRef: $scanReportRef}' \
	>"$WORKDIR/predicate.json"

if ! cue vet "$WORKDIR/predicate.json" -d '#Predicate' "$POLICY" 2>"$WORKDIR/cue.err"; then
	echo "approve: the predicate does not satisfy #Predicate — not signing" >&2
	sed 's/^/  /' "$WORKDIR/cue.err" >&2
	exit 5
fi

# --- 6. Sign. openbao:// => OpenBao Transit; no signing-config / no tlog so
#        nothing is published to a public transparency log (Codex P1-4). ---
before_digests="$(printf '%s' "$referrers" | jq -c '[.referrers[].digest]')"

if ! cosign attest \
	--predicate "$WORKDIR/predicate.json" \
	--type "$TYPE" \
	--key "$SIGNING_KEY" \
	--use-signing-config=false \
	--tlog-upload=false \
	"$IMAGE_REF"; then
	echo "approve: cosign attest failed — no durable record was written" >&2
	exit 6
fi

# --- 7. Read the attestation back and identify its digest. New bundle
#        referrers only, then match the one carrying THIS decision by its
#        predicate contents — registries differ on which referrer
#        annotations they echo back (GHCR omits the predicateType one), so
#        the predicate itself is the only reliable discriminator. ---
after_json="$(oras discover "${ORAS_HTTP[@]}" --format json "$IMAGE_REF")"
new_bundles="$(printf '%s' "$after_json" | jq -r --argjson before "$before_digests" '
  .referrers[]
  | select(.artifactType == "application/vnd.dev.sigstore.bundle.v0.3+json")
  | select(.digest as $d | ($before | index($d)) | not)
  | .digest
')"

ATT_DIGEST=""
# shellcheck disable=SC2086  # one digest per line, deliberate word-split
for cand in $new_bundles; do
	cand_mf="$(oras manifest fetch "${ORAS_HTTP[@]}" "${REPO}@${cand}")"
	cand_layer="$(printf '%s' "$cand_mf" | jq -r '.layers[0].digest')"
	oras blob fetch "${ORAS_HTTP[@]}" --output "$WORKDIR/cand.json" "${REPO}@${cand_layer}"
	pred="$(jq -r '.dsseEnvelope.payload' "$WORKDIR/cand.json" | base64 -d | jq -c '.predicate')"
	if [ "$(printf '%s' "$pred" | jq -r '.verdict')" = "$verdict" ] &&
		[ "$(printf '%s' "$pred" | jq -r '.digest')" = "$IMAGE_DIGEST" ] &&
		[ "$(printf '%s' "$pred" | jq -r '.approvedAt')" = "$APPROVED_AT" ]; then
		ATT_DIGEST="$cand"
		break
	fi
done

if [ -z "$ATT_DIGEST" ]; then
	echo "approve: cosign attest reported success but this decision's attestation is not discoverable" >&2
	echo "  the registry push may have failed after signing — treat this digest as NOT approved" >&2
	exit 6
fi

# --- 8. Tell the operator what to record ---
echo
if [ "$verdict" = "approved" ]; then
	echo "APPROVED  $IMAGE_DIGEST"
else
	echo "REJECTED  $IMAGE_DIGEST   (a signed record — consumers pinning this digest will refuse it)"
fi
echo "attestation digest: $ATT_DIGEST"
echo
echo "record it:  mise run consume -- $IMAGE_REF $ATT_DIGEST"
