#!/usr/bin/env bash
set -euo pipefail

# hk `chainsaw-frontend` step — the [k8s]-gated running-state check for the
# cv_frontend in-cluster delivery (Plan B M3, docs/adr/0019). Same gate
# shape as flux-chainsaw.sh / kyverno-chainsaw.sh:
#
#   - no chainsaw / no kube-context / cluster unreachable -> skip, exit 0
#   - the `frontend` Flux Kustomization absent -> skip, exit 0 (the M3 Flux
#     objects have not reconciled onto this cluster yet — they only exist
#     once this branch is on the ref the FluxInstance syncs, i.e. after
#     merge; same as ci-reconcile in flux-chainsaw.sh)
#
# It asserts DELIVERY, not app health: the cv_frontend app has a known Remix
# v3 boot crash (deploy/frontend/README.md), so the tests check that the
# rendered Deployment carries the approved image digest and that K1's
# ImageValidatingPolicy admitted it — NOT that the pod is Available.
#
# Two Tests (chainsaw's default --test-file is the fixed name `chainsaw-test`,
# so each needs its own subdir):
#   reconcile/  the OCIRepository + the dependsOn chain (frontend-ns AND
#               kyverno-policy) are Ready
#   delivery/   the Deployment exists, runs the approved image digest, and
#               its pod's container actually started
#
# Test seam: TOOLBOX_FRONTEND_SKIP_CHAINSAW=1 forces the skip path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/../tests/frontend" && pwd)"
CONTEXT="${TOOLBOX_FRONTEND_KUBE_CONTEXT:-orbstack}"

skip() {
	echo "frontend-chainsaw: $* — skipping ([k8s] gate)"
	exit 0
}

[ -z "${TOOLBOX_FRONTEND_SKIP_CHAINSAW:-}" ] || skip "TOOLBOX_FRONTEND_SKIP_CHAINSAW set"
command -v chainsaw >/dev/null || skip "chainsaw not on PATH"
kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$CONTEXT" ||
	skip "no '$CONTEXT' kube-context"
kubectl --context "$CONTEXT" cluster-info >/dev/null 2>&1 ||
	skip "'$CONTEXT' cluster unreachable"
kubectl --context "$CONTEXT" -n flux-system get kustomization.kustomize.toolkit.fluxcd.io frontend >/dev/null 2>&1 ||
	skip "the frontend Flux Kustomization is not reconciled (environments/local/flux/frontend.yaml)"

exec chainsaw test --kube-context "$CONTEXT" --test-dir "$TESTS_DIR"
