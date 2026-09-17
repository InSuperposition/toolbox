#!/usr/bin/env bash
set -euo pipefail

# hk `chainsaw-kyverno` step — the [k8s]-gated running-state check for every
# Kyverno policy under environments/local/kyverno/. Same gate shape as
# environments/local/scripts/flux-chainsaw.sh / openbao-chainsaw.sh:
#
#   - no chainsaw / no kube-context / cluster unreachable -> skip, exit 0
#     (GitHub runners have no OrbStack — this must not be fatal in CI)
#   - any policy this directory's tests exercise is absent -> skip, exit 0
#     (the `kyverno-policy` Flux Kustomization has not reconciled onto this
#     cluster yet — it only exists once this branch is on the ref the
#     FluxInstance syncs, i.e. after merge; same as ci-reconcile in
#     flux-chainsaw.sh). One shared skip gate for the whole directory: a
#     single chainsaw invocation below covers every Test under it, so a
#     missing policy for ANY of them means a clean skip, not a slow timeout
#     waiting on that Test's own internal readiness assert.
#
# `frontend-approval` (ImageValidatingPolicy) asserts admission behaviour
# against a REAL approved cv_frontend digest and a REAL unsigned one — the
# live equivalent of `attestation-verify.sh`. The deny variants (signed
# rejection, wrong subject, malformed predicate) are proven by a build-time
# spike that live-proved semantic equivalence to attestation-verify.sh for
# all four approval-selection cases, plus attestation-verify.bats — this
# test's unique value is that the Flux-reconciled policy gates a real
# cv_frontend pod BOTH ways.
#
# `buildkit-build-posture` (ValidatingPolicy) asserts the rootless-BuildKit
# securityContext ceiling is enforced at admission on any pod's `build`
# container, complementing the static Task-manifest assert in
# ci/tests/build-pipeline/chainsaw-test.yaml.
#
# Neither installs anything or tears down beyond the pods each Test creates.
#
# Test seam: TOOLBOX_KYVERNO_SKIP_CHAINSAW=1 forces the skip path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/../tests/kyverno" && pwd)"
CONTEXT="${TOOLBOX_KYVERNO_KUBE_CONTEXT:-orbstack}"

# The repo-root chainsaw config (.chainsaw.yaml — namespace.fastDelete so a
# loaded single-node cluster's slow ephemeral-namespace teardown does not
# fail the run). Resolved by a marker walk, not a `../..` climb.
REPO_ROOT="$SCRIPT_DIR"
while [ "$REPO_ROOT" != / ] && [ ! -e "$REPO_ROOT/mise.toml" ]; do REPO_ROOT="$(dirname "$REPO_ROOT")"; done

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
kubectl --context "$CONTEXT" get validatingpolicy buildkit-build-posture >/dev/null 2>&1 ||
	skip "the buildkit-build-posture ValidatingPolicy is not reconciled (kyverno-policy Kustomization)"

exec chainsaw test --config "$REPO_ROOT/.chainsaw.yaml" --kube-context "$CONTEXT" --test-dir "$TESTS_DIR"
