#!/usr/bin/env bash
set -euo pipefail

# The one place in the digest-as-source-of-truth pipeline with real logic:
# gather the build evidence, put it in front of a human, take their
# approve/reject decision, and sign it as an in-toto attestation over the
# image digest (docs/designs/digest-as-source-of-truth.md § Architecture).
#
#   mise run attestation:sign -- <registry/repo@sha256:...>
#
# Consumer-agnostic (docs/designs/repo-structure.md, ADR 0013): this seam
# signs and verifies approval records; it never names a consumer.
#
# Signs with openbao://approval-key (OpenBao Transit, key material never
# leaves OpenBao). ALWAYS writes a signed record — approve OR reject, never
# silent — EXCEPT when the operator aborts at the prompt (EOF / Ctrl-C /
# empty), which writes nothing.
#
# Selection model: this prints the new attestation's own digest. A consumer
# pins THAT digest — `mise run frontend:deploy -- <ref> <attestation-digest>`
# for the local demo — so a later reject, or a signed reject sitting next to
# this approval, does not change what an already-pinned consumer sees.
#
# Interim auth (a per-member authn/authz design is a separate deferred task,
# no trigger yet — TODOS.md "Auth + multi-member DX"): signing authenticates to OpenBao with
# the root token in $VAULT_TOKEN (mise [env] reads the 0600 root.token file,
# ADR 0011); pushing to a non-local registry uses `gh auth token` at call
# time. Both are per-operator and call-time,
# no stored registry secret. approvedBy is therefore self-asserted.
#
# Exit codes: 0 ok · 1 operator aborted · 2 bad args · 3 OpenBao unavailable
# (openbao-preflight.sh) · 4 build evidence missing · 5 predicate failed its
# own schema · 6 signing / registry push failed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null  # lib is exercised via attestation-sign.bats
. "$SCRIPT_DIR/lib/attestation.sh"

TYPE="$ATTESTATION_TYPE"
KEY_NAME="approval-key"
SBOM_ARTIFACT_TYPE="application/vnd.cyclonedx+json"
SCAN_ARTIFACT_TYPE="application/vnd.trivy.report+json"
BUNDLE_ARTIFACT_TYPE="application/vnd.dev.sigstore.bundle.v0.3+json"  # matches attestation-verify.sh

# Signing key. The real value is openbao://approval-key (OpenBao Transit).
# TOOLBOX_APPROVE_KEY overrides it with a local cosign key file for the bats
# tests ONLY — a local key needs no OpenBao, so the preflight is skipped
# when the override is set. Never set this in real use.
SIGNING_KEY="${TOOLBOX_APPROVE_KEY:-openbao://$KEY_NAME}"

POLICY="$SCRIPT_DIR/../verdict-approved.cue"

usage() {
	echo "usage: mise run attestation:sign -- <registry/repo@sha256:<64 hex>>" >&2
	exit 2
}

[ $# -eq 1 ] || usage
IMAGE_REF="$1"

# Full digest reference only — a tag is mutable, which is the whole point of
# this pipeline. `repo:tag` and `repo` (no digest) are rejected here.
if ! attestation_is_digest_ref "$IMAGE_REF"; then
	echo "attestation-sign: '$IMAGE_REF' is not a full digest reference" >&2
	echo "  need: registry/repo@sha256:<64 hex>   (a tag is not accepted — it is mutable)" >&2
	exit 2
fi

REPO="${IMAGE_REF%@*}"
IMAGE_DIGEST="${IMAGE_REF##*@}"
REGISTRY_HOST="${REPO%%/*}"

# Local dev registries speak http and need no auth; everything else is GHCR
# over https with a call-time `gh` token (interim auth).
ORAS_HTTP=()
if attestation_is_local_registry "$REGISTRY_HOST"; then
	ORAS_HTTP=(--plain-http)
	LOCAL_REGISTRY=1
else
	LOCAL_REGISTRY=0
fi

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
	command -v gh >/dev/null || { echo "attestation-sign: gh not on PATH (interim registry auth)" >&2; exit 6; }
	export DOCKER_CONFIG="$WORKDIR/docker"
	mkdir -p "$DOCKER_CONFIG"
	GH_USER="$(gh api user --jq .login)"
	if ! gh auth token | cosign login "$REGISTRY_HOST" -u "$GH_USER" --password-stdin >/dev/null 2>&1; then
		echo "attestation-sign: could not log in to $REGISTRY_HOST with the gh token" >&2
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
	echo "attestation-sign: build evidence missing on this digest: $missing" >&2
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
abort() { echo; echo "attestation-sign: aborted — no attestation written." >&2; exit 1; }

verdict=""
read -r -p "verdict [approve / reject]: " answer || abort
case "$answer" in
approve | a) verdict="approved" ;;
reject | r) verdict="rejected" ;;
"") abort ;;
*) echo "attestation-sign: expected 'approve' or 'reject', got '$answer'" >&2; abort ;;
esac

read -r -p "reason (required): " reason || abort
[ -n "$reason" ] || { echo "attestation-sign: a reason is required for both verdicts" >&2; abort; }

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
	echo "attestation-sign: the predicate does not satisfy #Predicate — not signing" >&2
	sed 's/^/  /' "$WORKDIR/cue.err" >&2
	exit 5
fi

# --- 6. Sign, but do NOT upload. We push the bundle as a referrer
#        ourselves in step 7, so `oras` reports the exact digest the
#        consumer must pin. cosign's own push gives no digest back, which is
#        why this used to re-`oras discover` and match the new referrer by
#        predicate contents (~35 lines, and fragile — registries differ on
#        which annotations they echo). openbao:// => OpenBao Transit; no
#        signing-config / no tlog so nothing hits a public transparency log
#        (Codex P1-4). ---
if ! cosign attest \
	--predicate "$WORKDIR/predicate.json" \
	--type "$TYPE" \
	--key "$SIGNING_KEY" \
	--use-signing-config=false \
	--tlog-upload=false \
	--no-upload \
	--bundle "$WORKDIR/att.bundle" \
	"$IMAGE_REF"; then
	echo "attestation-sign: cosign attest failed — no durable record was written" >&2
	exit 6
fi

# --- 7. Push the signed bundle as an OCI 1.1 referrer of the image; oras
#        prints the referrer manifest digest — that is ATT_DIGEST. The
#        assignment gets its own `if !` branch: a bare `ATT_DIGEST=$(...)`
#        would exit under `set -e` on push failure, before the check runs.
#        --disable-path-validation: att.bundle is our own mktemp workdir,
#        deliberately an absolute path (oras rejects those by default). ---
if ! ATT_DIGEST="$(oras attach "${ORAS_HTTP[@]}" \
		--artifact-type "$BUNDLE_ARTIFACT_TYPE" \
		--disable-path-validation \
		--format go-template --template '{{.digest}}' \
		"$IMAGE_REF" "$WORKDIR/att.bundle:$BUNDLE_ARTIFACT_TYPE")" ||
	[ -z "$ATT_DIGEST" ]; then
	echo "attestation-sign: signed OK but the referrer push failed — treat this digest as NOT approved" >&2
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
echo "record it:  mise run frontend:deploy -- $IMAGE_REF $ATT_DIGEST"
