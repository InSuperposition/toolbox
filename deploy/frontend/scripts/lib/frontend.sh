# shellcheck shell=bash
#
# deploy/frontend/scripts/lib/frontend.sh — shared shell for the frontend
# consumer's two scripts (frontend-deploy.sh / frontend-serve.sh).
# Self-contained, no repo-level runtime lib (docs/designs/repo-structure.md
# § Naming). Source it; do not execute.
#
# Its whole job is the ONE allowed cross-concern edge: deploy/frontend
# reaches the attestation verify seam. Per the DAG (repo-structure.md
# § The concerns) that edge runs through the TOOLBOX_ATTESTATION_VERIFY env
# seam — the same shape as TOOLBOX_APPROVAL_PUBKEY / TOOLBOX_APPROVE_KEY.
# The default is resolved through the checkout root (mise.toml marker), not
# a `../attestation` relative climb, so the boundary lint stays honest: a
# resolved path is fine, a relative climb into a sibling concern is not.

# frontend_repo_root — the checkout root, walking up from this lib for the
# mise.toml marker. Depth-independent.
frontend_repo_root() {
	local d
	d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	while [ "$d" != "/" ] && [ ! -e "$d/mise.toml" ]; do
		d="$(dirname "$d")"
	done
	[ -e "$d/mise.toml" ] || {
		echo "frontend_repo_root: no mise.toml above ${BASH_SOURCE[0]}" >&2
		return 1
	}
	printf '%s\n' "$d"
}

# frontend_attestation_verify <image-ref> <attestation-digest> — run the
# attestation verify seam. Honours $TOOLBOX_ATTESTATION_VERIFY (bats points
# it at a scratch copy); the default is the committed seam under
# attestation/. Passes the callee's exit code straight through (0 valid /
# 1 terminal / 2 bad args / 3 retryable).
frontend_attestation_verify() {
	local verify="${TOOLBOX_ATTESTATION_VERIFY:-}"
	if [ -z "$verify" ]; then
		verify="$(frontend_repo_root)/attestation/scripts/attestation-verify.sh"
	fi
	"$verify" "$@"
}
