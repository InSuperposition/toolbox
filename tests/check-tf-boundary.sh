#!/usr/bin/env bash
set -euo pipefail

# ADR 0018 — no OpenTofu `kubernetes_*` / `kubernetes_manifest` resource.
# OpenTofu owns the substrate; in-cluster Kubernetes objects go through Flux
# plain-YAML or (if ever activated) Crossplane, never tofu.
#
# ast-grep ships no HCL grammar (sgconfig.yml), so this is a `git grep`.
# The tri-state — match / no-match / grep-error — is classified explicitly:
# a bare `! git grep` would invert a grep ERROR into a green gate, the exact
# silent-no-op this file exists to avoid.
#
# Wired as the `no-kubernetes-tf` hk step; `tests/check-tf-boundary.bats`
# mutation-tests it.

root="$(git rev-parse --show-toplevel)"
cd "$root"

pattern='^[[:space:]]*resource[[:space:]]+"kubernetes(_manifest)?_'

set +e
hits="$(git grep -nE "$pattern" -- '*.tf')"
rc=$?
set -e

case "$rc" in
0)
	echo "check-tf-boundary: ADR 0018 violation — OpenTofu kubernetes_* resource(s):" >&2
	echo "$hits" >&2
	echo "  In-cluster objects go through Flux plain-YAML or Crossplane, never tofu." >&2
	exit 1
	;;
1)
	exit 0
	;;
*)
	echo "check-tf-boundary: git grep failed (rc=$rc) — gate inconclusive, failing closed" >&2
	exit "$rc"
	;;
esac
