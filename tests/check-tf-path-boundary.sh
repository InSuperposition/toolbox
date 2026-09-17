#!/usr/bin/env bash
set -euo pipefail

# No `file()` / `templatefile()` / `filebase64()` call in a .tf or .tftpl
# file may climb into a sibling concern (ci/ deploy/ attestation/ modules/
# environments/) — the same forbidden-climb list check-tf-boundary.sh's
# shell sibling (rules/boundary-shell-concern-climb.yml) already enforces
# for bash, now closing the same gap on the HCL layer (ast-grep ships no
# HCL grammar, so this is a `git grep`, same shape as check-tf-boundary.sh).
# A `${path.module}`-relative call within the same unit is fine.
#
# The tri-state — match / no-match / grep-error — is classified explicitly:
# a bare `! git grep` would invert a grep ERROR into a green gate, the exact
# silent-no-op this file exists to avoid.
#
# Wired as its own hk step; tests/check-tf-path-boundary.bats mutation-tests it.

root="$(git rev-parse --show-toplevel)"
cd "$root"

pattern='(file|templatefile|filebase64)\([^)]*"[^"]*(\.\./\.\./|\.\./(ci|deploy|attestation|modules|environments)/)'

set +e
hits="$(git grep -nEo "$pattern" -- '*.tf' '*.tftpl')"
rc=$?
set -e

case "$rc" in
0)
	echo "check-tf-path-boundary: cross-concern climb in a file()/templatefile()/filebase64() call:" >&2
	echo "$hits" >&2
	echo "  Reach another concern through a task call or an env seam instead." >&2
	exit 1
	;;
1)
	exit 0
	;;
*)
	echo "check-tf-path-boundary: git grep failed (rc=$rc) — gate inconclusive, failing closed" >&2
	exit "$rc"
	;;
esac
