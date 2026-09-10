#!/usr/bin/env bash
set -euo pipefail

# `mise run frontend:publish -- <registry/repo@sha256:...> <sha256:attestation-digest> <revision>`
#
# Render the cv_frontend Timoni module against the APPROVED image digest and
# publish the rendered manifests as an OCI artifact for Flux to reconcile
# (docs/adr/0019, Plan B M3).
#
# Verify FIRST — nothing is rendered or pushed unless the pinned approval
# attestation holds. This is the operator-boundary gate, the same shape as
# `frontend:deploy` and `attestation:sign` (the verify seam is the
# attestation/ concern's, reached through lib/frontend.sh's
# TOOLBOX_ATTESTATION_VERIFY seam — the one allowed cross-concern edge,
# repo-structure.md § The concerns, ADR 0013). The render + push are
# deterministic (`timoni build` is reproducible; a digest is content
# addressed), so they need no privileged in-cluster pipeline — a Tekton Task
# would only add a container image to source for a CLI that ships no image.
#
# Three distinct digests (docs/designs/digest-as-source-of-truth.md):
#   D_img — the approved cv_frontend container image ($1). Goes in the
#           rendered Deployment; K1's ImageValidatingPolicy verifies it.
#   D_att — the approval attestation on D_img ($2). Verified here.
#   D_man — the manifest-artifact digest this script PRINTS. A human copies
#           it into deploy/frontend/timoni.lock and
#           environments/local/flux/frontend.yaml in the reviewed PR — the
#           git pin is the reviewed artifact (ADR 0001). Never auto-committed.
#
# The push is to the loopback NodePort (plain HTTP, credential-free zot,
# `--insecure-registry`); the Flux `OCIRepository frontend` pulls the
# identical digest over the in-cluster Service DNS.
#
# Exit: 0 published · 1 verification failed (nothing rendered or pushed) ·
#       2 bad args · 5 timoni render failed · 6 flux push failed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null  # lib is exercised via frontend-publish.bats
. "$SCRIPT_DIR/lib/frontend.sh"

FRONTEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_DIR="$FRONTEND_DIR/timoni"
INSTANCE="cv-frontend"

usage() {
	echo "usage: mise run frontend:publish -- <registry/repo@sha256:<64 hex>> <sha256:<attestation-digest>> <revision>" >&2
	exit 2
}

[ $# -eq 3 ] || usage
IMAGE_REF="$1"
ATT_DIGEST="$2"
REVISION="$3"

case "$IMAGE_REF" in
*@sha256:*) : ;;
*) echo "frontend-publish: '$IMAGE_REF' is not a full digest reference (a tag is not accepted)" >&2; exit 2 ;;
esac
IMAGE_HEX="${IMAGE_REF##*@}"
frontend_strict_digest "$IMAGE_HEX" \
	|| { echo "frontend-publish: '$IMAGE_REF' does not end in a canonical sha256:<64 hex> digest" >&2; exit 2; }
frontend_strict_digest "$ATT_DIGEST" \
	|| { echo "frontend-publish: '$ATT_DIGEST' is not a canonical sha256:<64 hex> digest" >&2; exit 2; }
printf '%s' "$REVISION" | grep -Eq '^[0-9a-zA-Z._-]{1,128}$' \
	|| { echo "frontend-publish: '$REVISION' is not a usable OCI tag" >&2; exit 2; }

# --- 1. Verify — nothing below runs unless this passes. ---
frontend_attestation_verify "$IMAGE_REF" "$ATT_DIGEST" || {
	echo "frontend-publish: verification failed — nothing rendered or pushed" >&2
	exit 1
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- 2. Render the module against the approved digest. `timoni build` is
#        reproducible: the same module + the same values give the same
#        bytes, which is what makes D_man a meaningful pin. The image
#        repository/tag defaults live in images.cue; only the digest — the
#        trust anchor — is overridden here. ---
IMAGE_REPO="${IMAGE_REF%@*}"
cat >"$WORKDIR/values.cue" <<EOF
package main

values: {
	image: {
		repository: "${IMAGE_REPO}"
		digest:     "${IMAGE_HEX}"
	}
}
EOF

if ! timoni build "$INSTANCE" "$MODULE_DIR" -f "$WORKDIR/values.cue" --output yaml >"$WORKDIR/manifests.yaml"; then
	echo "frontend-publish: timoni build failed — nothing pushed" >&2
	exit 5
fi

# --- 3. Publish the rendered YAML as an OCI artifact. `flux push` prints the
#        digest with `--output json` — no `crane digest <tag>` race after. ---
MANIFESTS_HOST="$(cue export "$FRONTEND_DIR/pipelinerun.cue" -e image.manifests.host --out text)"
SOURCE_URL="$(git -C "$FRONTEND_DIR" config --get remote.origin.url)"
DEFS_SHA="$(git -C "$FRONTEND_DIR" rev-parse HEAD)"

if ! push_json="$(flux push artifact "oci://${MANIFESTS_HOST}:${REVISION}" \
	--path="$WORKDIR/manifests.yaml" \
	--source="$SOURCE_URL" \
	--revision="${REVISION}@sha1:${DEFS_SHA}" \
	--insecure-registry \
	--output=json)"; then
	echo "frontend-publish: flux push failed — treat this revision as NOT published" >&2
	exit 6
fi

D_MAN="$(printf '%s' "$push_json" | jq -r '.digest')"
frontend_strict_digest "$D_MAN" \
	|| { echo "frontend-publish: flux push returned no usable digest: $push_json" >&2; exit 6; }

MANIFESTS_INCLUSTER="$(cue export "$FRONTEND_DIR/pipelinerun.cue" -e image.manifests.inCluster --out text)"

echo
echo "PUBLISHED  ${MANIFESTS_HOST}:${REVISION}"
echo "  D_man (manifest artifact): $D_MAN"
echo "  D_img (approved image):    $IMAGE_HEX"
echo
echo "record it in the reviewed PR (the git pin IS the artifact — ADR 0001):"
echo "  deploy/frontend/timoni.lock         manifest_digest=$D_MAN"
echo "  environments/local/flux/frontend.yaml  OCIRepository frontend  ref.digest: $D_MAN"
echo "  (Flux pulls oci://${MANIFESTS_INCLUSTER}@${D_MAN})"
