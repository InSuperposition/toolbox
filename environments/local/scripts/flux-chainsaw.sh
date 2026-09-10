#!/usr/bin/env bash
set -euo pipefail

# hk `chainsaw` step for the environments/local/ Flux setup. [k8s]-gated:
# without an orbstack cluster running a bootstrapped Flux it prints a skip
# line and exits 0 — GitHub runners have no OrbStack (same precedent as
# ci/scripts/chainsaw-test.sh).
#
# With a cluster + Flux it runs `chainsaw test` over the runnable subdirs of
# environments/local/tests/flux/. Each subdir holds ONE Test asserting the
# RUNNING state of one slice of the reconcile — it does NOT bootstrap or
# tear down (the bootstrap path + drift-and-revert are the documented
# `mise run local:flux:bootstrap` acceptance run, PR #19).
#
# SUBDIR GATING (`subdir_gate`): a subdir whose CRs are merged to `main`
# ALWAYS runs — a regression that drops one from the Flux inventory must
# turn the run RED, not green-skip (R1b-i eng review, Codex #4). A subdir
# whose CRs are not yet on the ref the FluxInstance syncs gets a `kubectl
# get` probe so a feature branch does not fail on the not-yet-reconciled
# state; that probe is transitional and removed once the chunk merges.
#
# Test seam: TOOLBOX_FLUX_SKIP_CHAINSAW=1 forces the skip path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/../tests/flux" && pwd)"
CONTEXT="${TOOLBOX_FLUX_KUBE_CONTEXT:-orbstack}"

# The repo-root chainsaw config (.chainsaw.yaml — namespace.fastDelete so a
# loaded single-node cluster's slow ephemeral-namespace teardown does not
# fail the run). Resolved by a marker walk, not a `../..` climb.
REPO_ROOT="$SCRIPT_DIR"
while [ "$REPO_ROOT" != / ] && [ ! -e "$REPO_ROOT/mise.toml" ]; do REPO_ROOT="$(dirname "$REPO_ROOT")"; done

skip() {
	echo "flux-chainsaw: $* — skipping ([k8s] gate)"
	exit 0
}

# Per-subdir gate. Exit 0 => run the subdir. Exit non-zero => skip it.
# Keep `flux-reconcile` + any merged chunk in the always-run arm; only a
# not-yet-on-`main` chunk gets a probe (and only until it merges).
subdir_gate() {
	case "$1" in
	flux-reconcile | trust-manager-reconcile) return 0 ;;
	ci-reconcile)
		# ci-runtime Kustomization exists on the cluster only once
		# environments/local/flux/{ci-runtime,ci-defs}.yaml are on the synced
		# ref (T7c Increment 2 — merged PR #21; probe kept for branch safety).
		kubectl --context "$CONTEXT" -n flux-system \
			get kustomization.kustomize.toolkit.fluxcd.io ci-runtime >/dev/null 2>&1
		;;
	*) return 0 ;; # a new subdir defaults to always-run
	esac
}

[ -z "${TOOLBOX_FLUX_SKIP_CHAINSAW:-}" ] || skip "TOOLBOX_FLUX_SKIP_CHAINSAW set"
command -v chainsaw >/dev/null || skip "chainsaw not on PATH"
kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$CONTEXT" ||
	skip "no '$CONTEXT' kube-context"
kubectl --context "$CONTEXT" cluster-info >/dev/null 2>&1 ||
	skip "'$CONTEXT' cluster unreachable"
kubectl --context "$CONTEXT" -n flux-system get fluxinstance flux >/dev/null 2>&1 ||
	skip "Flux not bootstrapped (mise run local:flux:bootstrap)"

run_dirs=()
for d in "$TESTS_DIR"/*/; do
	[ -d "$d" ] || continue
	name="$(basename "$d")"
	if subdir_gate "$name"; then
		run_dirs+=("$d")
		echo "flux-chainsaw: + $name"
	else
		echo "flux-chainsaw: - $name (gate probe negative — CRs not on the synced ref yet)"
	fi
done

[ "${#run_dirs[@]}" -gt 0 ] || skip "no runnable tests/flux subdirs"

args=(test --config "$REPO_ROOT/.chainsaw.yaml" --kube-context "$CONTEXT")
for d in "${run_dirs[@]}"; do args+=(--test-dir "$d"); done
exec chainsaw "${args[@]}"
