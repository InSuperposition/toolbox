#!/usr/bin/env bash
set -euo pipefail

# hk `chainsaw` step for the environments/local/ Flux setup. [k8s]-gated:
# without an orbstack cluster running a bootstrapped Flux it prints a skip
# line and exits 0 — GitHub runners have no OrbStack (same precedent as
# ci/scripts/chainsaw-test.sh).
#
# With a cluster + Flux it runs `chainsaw test` over
# environments/local/tests/flux/. The Test asserts the RUNNING Flux state
# (Ready conditions, the generated GitRepository artifact, the cosign-verified
# OCIRepository, the adopted HelmRelease, the zot Kustomization) — it does
# NOT bootstrap or tear down. The full bootstrap path is the documented
# `mise run local:flux:bootstrap` acceptance run (PR #19), and the
# drift-and-revert is a manual check in that same run.
#
# Test seam: TOOLBOX_FLUX_SKIP_CHAINSAW=1 forces the skip path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/../tests/flux" && pwd)"
CONTEXT="${TOOLBOX_FLUX_KUBE_CONTEXT:-orbstack}"

skip() {
	echo "flux-chainsaw: $* — skipping ([k8s] gate)"
	exit 0
}

[ -z "${TOOLBOX_FLUX_SKIP_CHAINSAW:-}" ] || skip "TOOLBOX_FLUX_SKIP_CHAINSAW set"
command -v chainsaw >/dev/null || skip "chainsaw not on PATH"
kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$CONTEXT" ||
	skip "no '$CONTEXT' kube-context"
kubectl --context "$CONTEXT" cluster-info >/dev/null 2>&1 ||
	skip "'$CONTEXT' cluster unreachable"
kubectl --context "$CONTEXT" -n flux-system get fluxinstance flux >/dev/null 2>&1 ||
	skip "Flux not bootstrapped (mise run local:flux:bootstrap)"

echo "flux-chainsaw: running chainsaw test over environments/local/tests/flux/"
exec chainsaw test --kube-context "$CONTEXT" "$TESTS_DIR"
