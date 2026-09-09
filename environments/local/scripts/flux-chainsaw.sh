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

# tests/flux/ has one subdir per Test (chainsaw's default --test-file is the
# fixed name `chainsaw-test`, so a second Test needs its own subdir — same
# layout as ci/tests/<name>/chainsaw-test.yaml):
#
#   flux-reconcile/  the PR #19/#20 running-Flux checks — always run
#   ci-reconcile/    the T7c Increment 2 ci/{runtime,tasks,pipelines} reconcile
#
# ci-reconcile asserts the ci-runtime / ci-tasks / ci-pipelines Kustomization
# CRs, which exist on the cluster only once this branch's
# environments/local/flux/{ci-runtime,ci-defs}.yaml are on the ref the
# FluxInstance syncs. Until then, run flux-reconcile only. Probe: the
# ci-runtime Kustomization in flux-system. (chainsaw 0.2.15's
# --exclude-test-regex does not filter reliably — scope by --test-dir.)
if kubectl --context "$CONTEXT" -n flux-system \
	get kustomization.kustomize.toolkit.fluxcd.io ci-runtime >/dev/null 2>&1; then
	target="$TESTS_DIR"
	echo "flux-chainsaw: running chainsaw over environments/local/tests/flux/ (all tests)"
else
	target="$TESTS_DIR/flux-reconcile"
	echo "flux-chainsaw: ci-runtime Kustomization absent — running flux-reconcile only" \
		"(ci-reconcile needs the T7c Increment 2 CRs on the synced ref)"
fi

exec chainsaw test --kube-context "$CONTEXT" "$target"
