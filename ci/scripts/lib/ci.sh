# shellcheck shell=bash
#
# ci/scripts/lib/ci.sh — shared shell for the ci/ concern's scripts
# (ci-taskrun.sh today; pipeline-bundle-push.sh in T7b). Self-contained,
# no repo-level runtime lib (docs/designs/repo-structure.md § Naming).
# Source it; do not execute.
#
# Consumer-agnostic (ADR 0014): nothing here names a consumer or a
# deploy/ path — callers pass concrete paths as arguments.

# ci_repo_root — the checkout root, walking up from this lib for the
# mise.toml marker. Depth-independent (F2, same idiom as lib/frontend.sh).
ci_repo_root() {
	local d
	d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	while [ "$d" != "/" ] && [ ! -e "$d/mise.toml" ]; do
		d="$(dirname "$d")"
	done
	[ -e "$d/mise.toml" ] || {
		echo "ci_repo_root: no mise.toml above ${BASH_SOURCE[0]}" >&2
		return 1
	}
	printf '%s\n' "$d"
}

# ci_is_strict_digest <s> — true only for a canonical image manifest
# digest: literally "sha256:" + exactly 64 lowercase hex. This repo's
# thesis is that the digest IS the trust boundary (ADR 0001), so a tag, a
# short digest, or "sha256:" + uppercase is a hard reject, not a warning.
ci_is_strict_digest() {
	case "$1" in
	sha256:*)
		local hex="${1#sha256:}"
		[ "${#hex}" -eq 64 ] && [ -z "${hex//[0-9a-f]/}" ]
		;;
	*) return 1 ;;
	esac
}

# ci_kube_context — the kube-context every kubectl/tkn call is pinned to.
# Overridable for tests; the default is orbstack (Codex #9 — never act on
# whatever context happens to be current).
ci_kube_context() { printf '%s\n' "${TOOLBOX_CI_KUBE_CONTEXT:-orbstack}"; }

# ci_namespace — the namespace ci/runtime/namespace.yaml defines.
ci_namespace() { printf '%s\n' "${TOOLBOX_CI_NAMESPACE:-ci}"; }

# ci_kubectl <args...> — kubectl with the context forced. Use this, never a
# bare `kubectl`, so a run can never touch a non-orbstack cluster.
ci_kubectl() { kubectl --context "$(ci_kube_context)" "$@"; }

# ci_require_context — fail unless the pinned context both exists in the
# kubeconfig and is reachable. Names the fix.
ci_require_context() {
	local ctx
	ctx="$(ci_kube_context)"
	if ! kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$ctx"; then
		echo "ci: kube-context '$ctx' not in the kubeconfig — start OrbStack k8s (\`orb start k8s\`)" >&2
		return 1
	fi
	if ! ci_kubectl cluster-info >/dev/null 2>&1; then
		echo "ci: kube-context '$ctx' is unreachable — is \`orb start k8s\` up?" >&2
		return 1
	fi
}
