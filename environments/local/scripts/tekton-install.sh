#!/usr/bin/env bash
set -euo pipefail

# environments/local/scripts/tekton-install.sh — interim pinned install of the
# Tekton Pipelines controller on the local OrbStack k8s cluster.
#
# environments/local/ owns vendored-upstream installs (Tekton's controller,
# zot) — never ci/, same split as the OpenBao unit (README).
#
# Downloads `<base-url>/<version>/release.yaml`, verifies its SHA-256 against
# environments/local/tekton/release.lock, and only then applies the VERIFIED
# LOCAL FILE. `kubectl apply -f <url>` is never used — the digest/checksum is
# the trust boundary. A mismatch is a hard refusal, not a warning.
#
# Flux cannot install an absent Tekton, so the controller install stays a
# named external prerequisite for the `ci-runtime` Flux Kustomization; only
# the Task/Pipeline *defs* (ci/tasks, ci/pipelines) move to Flux, never the
# controller (README § Tekton).
#
# Test seams (environments/local/scripts/tests/tekton-install.bats):
#   TOOLBOX_TEKTON_LOCK              override the lock-file path
#   TOOLBOX_TEKTON_RELEASE_BASE_URL  override the GCS base URL
#   TOOLBOX_TEKTON_KUBE_CONTEXT      override the kube-context (default orbstack)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LOCK="${TOOLBOX_TEKTON_LOCK:-$ENV_DIR/tekton/release.lock}"
BASE_URL="${TOOLBOX_TEKTON_RELEASE_BASE_URL:-https://storage.googleapis.com/tekton-releases/pipeline/previous}"
CONTEXT="${TOOLBOX_TEKTON_KUBE_CONTEXT:-orbstack}"

die() {
	echo "tekton-install: $*" >&2
	exit 1
}

[ -f "$LOCK" ] || die "lock file not found: $LOCK"

version="$(sed -n 's/^version=//p' "$LOCK")"
sha256="$(sed -n 's/^sha256=//p' "$LOCK")"

[ -n "$version" ] || die "no 'version=' in $LOCK"
{ [ "${#sha256}" -eq 64 ] && [ -z "${sha256//[0-9a-f]/}" ]; } ||
	die "'sha256=' in $LOCK is not 64 lowercase hex: '$sha256'"

url="$BASE_URL/$version/release.yaml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
manifest="$tmp/release.yaml"

echo "tekton-install: downloading $url"
curl -sSfL "$url" -o "$manifest" || die "download failed: $url"

actual="$(shasum -a 256 "$manifest" | awk '{print $1}')"
[ "$actual" = "$sha256" ] ||
	die "checksum mismatch for $url — expected $sha256, got $actual. Refusing to apply."

echo "tekton-install: checksum OK — applying Tekton Pipelines $version (context '$CONTEXT')"
kubectl --context "$CONTEXT" apply --server-side -f "$manifest"

# The pinned release ships enable-api-fields=beta by default. `stdoutConfig`
# (a step's stdout duplicated to a file, consumed declaratively by a later
# step via $(steps.<name>.results.<name>) — no embedded shell) needs alpha.
# The BASE manifest above stays untouched and checksum-verified (the trust
# boundary) — this is a small, separate, auditable patch applied after it,
# same pattern the OpenBao bridge uses for its own post-apply steps.
# Idempotent: a merge patch to an unchanged value is a no-op.
echo "tekton-install: patching feature-flags (enable-api-fields: alpha, for stdoutConfig)"
kubectl --context "$CONTEXT" patch configmap feature-flags -n tekton-pipelines \
	--type merge -p '{"data":{"enable-api-fields":"alpha"}}'
