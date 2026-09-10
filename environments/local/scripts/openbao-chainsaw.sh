#!/usr/bin/env bash
set -euo pipefail

# hk `chainsaw-openbao` step — the [k8s]-gated running-state check
# for the in-cluster OpenBao Same gate shape as
# environments/local/scripts/flux-chainsaw.sh:
#
#   - no chainsaw / no kube-context / cluster unreachable -> skip, exit 0
#     (GitHub runners have no OrbStack — this must not be fatal in CI)
#   - the `openbao` StatefulSet in ns `openbao` absent -> skip, exit 0
#     (openbao-bootstrap.sh has not run on this cluster yet)
#   - otherwise: `chainsaw test` over environments/local/tests/openbao/
#
# It asserts the RUNNING post-migration state; it does NOT run the bridge or
# tear anything down.
#
# Test seam: TOOLBOX_OPENBAO_SKIP_CHAINSAW=1 forces the skip path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/../tests/openbao" && pwd)"
CONTEXT="${TOOLBOX_OPENBAO_KUBE_CONTEXT:-orbstack}"

skip() {
	echo "openbao-chainsaw: $* — skipping ([k8s] gate)"
	exit 0
}

[ -z "${TOOLBOX_OPENBAO_SKIP_CHAINSAW:-}" ] || skip "TOOLBOX_OPENBAO_SKIP_CHAINSAW set"
command -v chainsaw >/dev/null || skip "chainsaw not on PATH"
kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$CONTEXT" ||
	skip "no '$CONTEXT' kube-context"
kubectl --context "$CONTEXT" cluster-info >/dev/null 2>&1 ||
	skip "'$CONTEXT' cluster unreachable"
kubectl --context "$CONTEXT" -n openbao get statefulset openbao >/dev/null 2>&1 ||
	skip "in-cluster OpenBao not deployed (mise run local:openbao:bootstrap)"

exec chainsaw test --kube-context "$CONTEXT" --test-dir "$TESTS_DIR"
