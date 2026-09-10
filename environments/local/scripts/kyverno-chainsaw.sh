#!/usr/bin/env bash
set -euo pipefail

# hk `chainsaw-kyverno` step — the [k8s]-gated running-state check for the
# Kyverno ImageValidatingPolicy (Plan B K1, docs/adr/0020). Same gate shape
# as environments/local/scripts/flux-chainsaw.sh / openbao-chainsaw.sh:
#
#   - no chainsaw / no kube-context / cluster unreachable -> skip, exit 0
#     (GitHub runners have no OrbStack — this must not be fatal in CI)
#   - the `frontend-approval` ImageValidatingPolicy absent -> skip, exit 0
#     (the `kyverno-policy` Flux Kustomization has not reconciled onto this
#     cluster yet — it only exists once this branch is on the ref the
#     FluxInstance syncs, i.e. after merge; same as ci-reconcile in
#     flux-chainsaw.sh)
#
# It asserts admission behaviour against a REAL approved cv_frontend digest
# and a REAL unsigned one — the live equivalent of `attestation-verify.sh`.
# It does NOT install Kyverno or tear anything down. The deny variants
# (signed rejection, wrong subject, malformed predicate) are proven by the
# K1 T6 build-time spike (docs/adr/0020) and attestation-verify.bats — this
# test's unique value is that the Flux-reconciled policy gates a real
# cv_frontend pod BOTH ways.
#
# Test seam: TOOLBOX_KYVERNO_SKIP_CHAINSAW=1 forces the skip path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/../tests/kyverno" && pwd)"
CONTEXT="${TOOLBOX_KYVERNO_KUBE_CONTEXT:-orbstack}"

skip() {
	echo "kyverno-chainsaw: $* — skipping ([k8s] gate)"
	exit 0
}

[ -z "${TOOLBOX_KYVERNO_SKIP_CHAINSAW:-}" ] || skip "TOOLBOX_KYVERNO_SKIP_CHAINSAW set"
command -v chainsaw >/dev/null || skip "chainsaw not on PATH"
kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$CONTEXT" ||
	skip "no '$CONTEXT' kube-context"
kubectl --context "$CONTEXT" cluster-info >/dev/null 2>&1 ||
	skip "'$CONTEXT' cluster unreachable"
kubectl --context "$CONTEXT" get imagevalidatingpolicy frontend-approval >/dev/null 2>&1 ||
	skip "the frontend-approval ImageValidatingPolicy is not reconciled (kyverno-policy Kustomization)"

exec chainsaw test --kube-context "$CONTEXT" --test-dir "$TESTS_DIR"
