#!/usr/bin/env bash
set -euo pipefail

# hk `chainsaw-spire` step — the [k8s]-gated running-state check for the
# in-cluster SPIRE Server + Agent. Same gate shape as
# environments/local/scripts/openbao-chainsaw.sh:
#
#   - no chainsaw / no kube-context / cluster unreachable -> skip, exit 0
#     (GitHub runners have no OrbStack — this must not be fatal in CI)
#   - the `spire-server` StatefulSet in ns `spire` absent -> skip, exit 0
#     (spire-bootstrap.sh has not run on this cluster yet)
#   - otherwise: `chainsaw test` over environments/local/tests/spire/
#
# It asserts the RUNNING post-bootstrap state; it does NOT run the bridge
# or tear anything down.
#
# Test seam: TOOLBOX_SPIRE_SKIP_CHAINSAW=1 forces the skip path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/../tests/spire" && pwd)"
CONTEXT="${TOOLBOX_SPIRE_KUBE_CONTEXT:-orbstack}"

# The repo-root chainsaw config (.chainsaw.yaml — `namespace.fastDelete` so a
# loaded single-node cluster's slow ephemeral-namespace teardown does not
# fail the run). Resolved by a marker walk, not a `../../` climb.
REPO_ROOT="$SCRIPT_DIR"
while [ "$REPO_ROOT" != / ] && [ ! -e "$REPO_ROOT/mise.toml" ]; do REPO_ROOT="$(dirname "$REPO_ROOT")"; done

skip() {
	echo "spire-chainsaw: $* — skipping ([k8s] gate)"
	exit 0
}

[ -z "${TOOLBOX_SPIRE_SKIP_CHAINSAW:-}" ] || skip "TOOLBOX_SPIRE_SKIP_CHAINSAW set"
command -v chainsaw >/dev/null || skip "chainsaw not on PATH"
kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$CONTEXT" ||
	skip "no '$CONTEXT' kube-context"
kubectl --context "$CONTEXT" cluster-info >/dev/null 2>&1 ||
	skip "'$CONTEXT' cluster unreachable"
kubectl --context "$CONTEXT" -n spire get statefulset spire-server >/dev/null 2>&1 ||
	skip "in-cluster SPIRE not deployed (mise run local:spire:bootstrap)"

exec chainsaw test --config "$REPO_ROOT/.chainsaw.yaml" --kube-context "$CONTEXT" --test-dir "$TESTS_DIR"
