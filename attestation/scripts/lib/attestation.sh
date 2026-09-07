# shellcheck shell=bash
#
# attestation/scripts/lib/attestation.sh — shared shell for the sign and
# verify sides of the approval seam. Self-contained, no repo-level runtime
# lib (docs/designs/repo-structure.md § Naming). Source it; do not execute.
#
# What is shared is exactly what both sides must agree on: the in-toto
# predicate type string, what a valid image reference looks like, and the
# local-registry (plain-http, no auth) detection. Everything consumer- or
# side-specific stays in the scripts.

# The in-toto predicate type. cosign signs with it (--type) and verifies
# against it; a bump here needs a matching consumer change. Read by the
# sourcing script.
# shellcheck disable=SC2034
ATTESTATION_TYPE="https://insuperposition.github.io/toolbox/attestations/approval/v1"

# attestation_is_digest_ref <ref> — true when <ref> is a full digest
# reference (registry/repo@sha256:<64 hex>). A tag is mutable, which is the
# whole point of this pipeline, so `repo:tag` and `repo` are rejected.
attestation_is_digest_ref() {
	printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9.:_/-]+@sha256:[0-9a-f]{64}$'
}

# attestation_is_local_registry <registry-host> — true for a loopback dev
# registry (plain http, no auth — used by the bats suites). Everything else
# is a real registry over https.
attestation_is_local_registry() {
	case "${1:-}" in
	127.0.0.1:* | localhost:* | 127.0.0.1 | localhost) return 0 ;;
	*) return 1 ;;
	esac
}
