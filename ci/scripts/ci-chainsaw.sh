#!/usr/bin/env bash
set -euo pipefail

# hk `chainsaw` step for the ci/ concern. [k8s]-gated: without an orbstack
# cluster running Tekton it prints a skip line and exits 0 — T7a's
# in-cluster checks are a local spike, not a pre-merge gate, and GitHub
# runners have no OrbStack (ci/scripts/tests/helper.bash § [k8s] gate).
#
# With a cluster it runs `chainsaw test` over ci/tests/. chainsaw creates
# an ephemeral namespace per test and tears it down; the committed `ci`
# namespace is never touched.
#
# Test seam: TOOLBOX_CI_SKIP_CHAINSAW=1 forces the skip path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null  # lib is bats-tested directly (ci-chainsaw.bats)
. "$SCRIPT_DIR/lib/ci.sh"

skip() {
	echo "ci-chainsaw: $* — skipping ([k8s] gate)"
	exit 0
}

[ -z "${TOOLBOX_CI_SKIP_CHAINSAW:-}" ] || skip "TOOLBOX_CI_SKIP_CHAINSAW set"
command -v chainsaw >/dev/null || skip "chainsaw not on PATH"
ci_require_context 2>/dev/null || skip "no reachable '$(ci_kube_context)' context"
ci_kubectl -n "${TOOLBOX_CI_TEKTON_NS:-tekton-pipelines}" \
	get deployment/tekton-pipelines-controller >/dev/null 2>&1 ||
	skip "Tekton Pipelines not installed (mise run local:tekton:install)"

echo "ci-chainsaw: running chainsaw test over ci/tests/"
exec chainsaw test --kube-context "$(ci_kube_context)" "$SCRIPT_DIR/../tests"
