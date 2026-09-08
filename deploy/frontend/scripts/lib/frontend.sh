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

# --- frontend-build.sh helpers (T7b3) --------------------------------------
# frontend-build.sh fires the in-cluster build/scan/gate PipelineRun and
# watches it. deploy/frontend may NOT depend on ci/ (repo-structure.md
# § concerns), so the strict-digest check that ci/scripts/lib/ci.sh also
# carries is INLINED here, not sourced.

# frontend_kube_context — the kube-context every kubectl/tkn call is pinned
# to (A3 / Codex #7: never act on whatever context is current). Test seam.
frontend_kube_context() { printf '%s\n' "${TOOLBOX_KUBE_CONTEXT:-orbstack}"; }

# frontend_kube <args...> / frontend_tkn <args...> — kubectl / tkn with the
# context AND the `ci` namespace forced. Use these, never a bare kubectl/tkn
# (the default-vs-ci namespace bug that bit twice in T7b1fu / T7b2).
frontend_kube() { kubectl --context "$(frontend_kube_context)" -n ci "$@"; }
frontend_tkn() { tkn --context "$(frontend_kube_context)" -n ci "$@"; }

# frontend_strict_digest <s> — true only for a canonical manifest digest:
# literally "sha256:" + exactly 64 lowercase hex. The digest IS the trust
# boundary (ADR 0001); a tag, a short digest, or uppercase hex is a hard
# reject. (Same logic as ci_is_strict_digest — deliberately duplicated
# across the concern boundary rather than sourced.)
frontend_strict_digest() {
	case "$1" in
	sha256:*)
		local hex="${1#sha256:}"
		[ "${#hex}" -eq 64 ] && [ -z "${hex//[0-9a-f]/}" ]
		;;
	*) return 1 ;;
	esac
}

# frontend_host_image — cv_frontend's loopback registry ref (no tag), read
# from the ONE place both hostnames live (deploy/frontend/pipelinerun.cue).
frontend_host_image() {
	cue export "$(frontend_repo_root)/deploy/frontend/pipelinerun.cue" \
		-e image.host --out text
}
