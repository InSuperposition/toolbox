#!/usr/bin/env bash
set -euo pipefail

# Gathers build evidence for an image digest, shows it to a human, and signs
# their approve/reject decision as an in-toto attestation over that digest.
# This script only signs and verifies approval records — it never names or
# depends on a specific consumer.
#
#   mise run attestation:sign -- <registry/repo@sha256:...>
#
# Signs with openbao://approval-key (OpenBao Transit; key material never
# leaves OpenBao). Always writes a signed record — approve OR reject, never
# silent — except when the operator aborts at the prompt (EOF / Ctrl-C /
# empty input), which writes nothing.
#
# Selection model: this prints the new attestation's own digest. A consumer
# pins THAT digest (`mise run frontend:publish -- <ref> <attestation-digest>
# <revision>`), so a later reject, or a signed reject sitting next to this
# approval, does not change what an already-pinned consumer sees.
#
# The CLI argument is the multi-platform INDEX digest. Evidence discovery
# (SBOM/scan referrers) stays on that index — it is run-unique (its baked-in
# provenance entry carries a per-run timestamp), unlike a platform digest,
# which can collide across byte-identical rebuilds. Everything past evidence
# discovery — the signed subject, the pushed bundle referrer, and the
# recorded digest — instead uses the resolved linux/arm64 PLATFORM digest:
# Kyverno's ImageValidatingPolicy has no platform-selection config of its
# own and rejects an arm64-only index reference outright, so nothing past
# signing may reference the index again.
#
# Auth is interim and per-operator, call-time only — no stored registry
# secret, so approvedBy is self-asserted: signing authenticates to OpenBao
# with the root token in $VAULT_TOKEN; pushing to a non-local registry uses
# `gh auth token`.
#
# Exit codes: 0 ok · 1 operator aborted · 2 bad args · 3 OpenBao unavailable
# (openbao-preflight.sh) · 4 build evidence missing · 5 predicate failed its
# own schema · 6 signing / registry push failed · 7 platform-digest
# resolution failed (the given index has no linux/arm64 child).

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

# Three registry kinds: a loopback dev registry (plain http, no auth — the
# bats fixture); the in-cluster zot (https, no auth, but the dev CA needs an
# explicit file); everything else is GHCR over https with a call-time `gh`
# token.
ORAS_HTTP=()
COSIGN_CACERT=()
if attestation_is_local_registry "$REGISTRY_HOST"; then
	ORAS_HTTP=(--plain-http)
	LOCAL_REGISTRY=1
elif attestation_is_cluster_registry "$REGISTRY_HOST"; then
	CA_FILE="$(attestation_cluster_ca_file)"
	[ -f "$CA_FILE" ] || { echo "attestation-sign: dev CA not found at $CA_FILE — run 'mise run local:zot:trust' first" >&2; exit 6; }
	ORAS_HTTP=(--ca-file "$CA_FILE")
	COSIGN_CACERT=(--registry-cacert "$CA_FILE")
	LOCAL_REGISTRY=1
else
	LOCAL_REGISTRY=0
fi

# Resolve the arm64 PLATFORM digest for everything past this point (see
# header) using oras's own --platform flag, never a hand-rolled parser.
# Evidence discovery below deliberately stays on $IMAGE_REF (the index) —
# moving it to the platform digest would let find_referrer()'s `| last`
# pick collide across byte-identical rebuilds, since only the index's
# baked-in provenance entry is guaranteed run-unique.
PLATFORM_REPO="${IMAGE_REF%@*}"
PLATFORM_DIGEST="$(oras resolve "${ORAS_HTTP[@]}" --platform=linux/arm64 "$IMAGE_REF")" ||
	{ echo "attestation-sign: could not resolve a linux/arm64 manifest from $IMAGE_REF" >&2; exit 7; }
PLATFORM_REF="${PLATFORM_REPO}@${PLATFORM_DIGEST}"

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- 1. OpenBao must be able to sign before we waste the operator's time ---
if [ -z "${TOOLBOX_APPROVE_KEY:-}" ]; then
	"$SCRIPT_DIR/openbao-preflight.sh" "$KEY_NAME"
	: "${VAULT_ADDR:=https://openbao.openbao.svc.cluster.local:8200}"
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
	echo "  build this SHA first: mise run frontend:build -- <cv_frontend-sha>" >&2
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
	--arg digest "$PLATFORM_DIGEST" \
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

# --- 6. Sign, but do NOT upload. Step 7 pushes the bundle as a referrer
#        ourselves so `oras` reports the exact digest the consumer must
#        pin — cosign's own push gives no digest back, which previously
#        meant re-discovering and matching the new referrer by predicate
#        contents (fragile — registries differ on which annotations they
#        echo). openbao:// routes signing through OpenBao Transit; no
#        signing-config and no tlog upload, so nothing hits a public
#        transparency log. ---
if ! cosign attest \
	--predicate "$WORKDIR/predicate.json" \
	--type "$TYPE" \
	--key "$SIGNING_KEY" \
	--use-signing-config=false \
	--tlog-upload=false \
	--no-upload \
	--bundle "$WORKDIR/att.bundle" \
	"${COSIGN_CACERT[@]}" \
	"$PLATFORM_REF"; then
	echo "attestation-sign: cosign attest failed — no durable record was written" >&2
	exit 6
fi

# --- 7. Push the signed bundle as an OCI 1.1 referrer of the image; oras
#        prints the referrer manifest digest — that is ATT_DIGEST. The
#        assignment gets its own `if !` branch: a bare `ATT_DIGEST=$(...)`
#        would exit under `set -e` on push failure, before the check runs.
#        --disable-path-validation: att.bundle is our own mktemp workdir,
#        deliberately an absolute path (oras rejects those by default).
#
#        The two `dev.sigstore.bundle.*` manifest annotations mark this as
#        a bundle-format referrer for cosign's own discovery
#        (`cosign.GetBundles`) — a bare `oras attach` with only
#        `--artifact-type` is invisible to that path, so Kyverno's
#        ImageValidatingPolicy could not verify our attestations without
#        them. `attestation-verify.sh` is unaffected: it is handed the
#        referrer digest and reads `.layers[0]`, never the manifest
#        annotations. ---
if ! ATT_DIGEST="$(oras attach "${ORAS_HTTP[@]}" \
		--artifact-type "$BUNDLE_ARTIFACT_TYPE" \
		--annotation "dev.sigstore.bundle.content=dsse-envelope" \
		--annotation "dev.sigstore.bundle.predicateType=$TYPE" \
		--disable-path-validation \
		--format go-template --template '{{.digest}}' \
		"$PLATFORM_REF" "$WORKDIR/att.bundle:$BUNDLE_ARTIFACT_TYPE")" ||
	[ -z "$ATT_DIGEST" ]; then
	echo "attestation-sign: signed OK but the referrer push failed — treat this digest as NOT approved" >&2
	exit 6
fi

# --- 8. Tell the operator what to record ---
# Two digests shown deliberately: PLATFORM_DIGEST is what got signed and
# is deployable (Kyverno/kubelet resolve it directly, no index); the
# INDEX digest is the audit trail — which build's evidence this decision
# was based on. Only PLATFORM_DIGEST goes in the "record it" line below
# — that is the one value the next command (frontend:publish) needs.
echo
if [ "$verdict" = "approved" ]; then
	echo "APPROVED  $PLATFORM_DIGEST"
else
	echo "REJECTED  $PLATFORM_DIGEST   (a signed record — consumers pinning this digest will refuse it)"
fi
echo "  (evidence build: $IMAGE_DIGEST)"
echo "attestation digest: $ATT_DIGEST"
echo
echo "record it:  mise run frontend:publish -- $PLATFORM_REF $ATT_DIGEST <revision>"
