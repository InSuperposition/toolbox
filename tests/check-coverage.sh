#!/usr/bin/env bash
# tests/check-coverage.sh — guards against a silent test-coverage drop.
#
# The failure it catches (F5 — the one CRITICAL finding of the restructure
# review; see the toolbox-hk-glob-silent-coverage-drop learning): an
# `hk.pkl` glob edit, or a test file moved out of a matched path, quietly
# removes a whole suite from `mise run check` while the gate stays green —
# fewer tests still pass.
#
# Three independent views of the test set must agree:
#   1. the suites on disk    — this script's own `find`, NOT hk's globs
#   2. tests/manifest.txt     — the committed expectation (path + case count)
#   3. what hk schedules      — `hk check --all --plan --json` fileCount
#
# Any mismatch fails the gate and names the suite. Runs as its own `hk`
# step in the `check` hook, after `bats` and `tofu-test`.
#
# Usage: check-coverage.sh [manifest-path]   (the arg is for the mutation
# test in tests/check-coverage.bats — it points the script at a deliberately
# broken copy and asserts a non-zero exit).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${1:-$ROOT/tests/manifest.txt}"

[ -f "$MANIFEST" ] || {
	echo "check-coverage: manifest not found: $MANIFEST" >&2
	exit 2
}

fail=0
note() {
	echo "check-coverage: $*" >&2
	fail=1
}

# --- 1. suites on disk (independent discovery) ---------------------------
mapfile -t disk_bats < <(
	cd "$ROOT" && find . -name '*.bats' \
		-not -path './.git/*' -not -path '*/.terraform/*' |
		sed 's|^\./||' | sort
)
mapfile -t disk_tftest < <(
	cd "$ROOT" && find . -name '*.tftest.hcl' \
		-not -path './.git/*' -not -path '*/.terraform/*' |
		sed 's|^\./||' | sort
)

bats_cases() { bats --count "$ROOT/$1"; }
tftest_cases() { grep -cE '^[[:space:]]*run[[:space:]]+"' "$ROOT/$1"; }

# --- 2. the committed manifest -----------------------------------------
declare -A want_kind want_cases
while read -r kind path cases _rest; do
	[ -z "${kind:-}" ] && continue
	case "$kind" in \#*) continue ;; esac
	want_kind["$path"]="$kind"
	want_cases["$path"]="$cases"
done < <(sed 's/#.*//' "$MANIFEST")

check_kind() { # <kind> <disk-path>...
	local kind="$1" p actual
	shift
	for p in "$@"; do
		if [ -z "${want_kind[$p]:-}" ]; then
			note "UNTRACKED $kind suite on disk: $p — add it to tests/manifest.txt"
			continue
		fi
		[ "${want_kind[$p]}" = "$kind" ] ||
			note "kind mismatch for $p: manifest says ${want_kind[$p]}, disk is $kind"
		if [ "$kind" = bats ]; then actual="$(bats_cases "$p")"; else actual="$(tftest_cases "$p")"; fi
		[ "${want_cases[$p]}" = "$actual" ] ||
			note "CASE COUNT drift in $p: manifest=${want_cases[$p]} actual=$actual"
		unset "want_kind[$p]" "want_cases[$p]"
	done
}

[ "${#disk_bats[@]}" -gt 0 ] && check_kind bats "${disk_bats[@]}"
[ "${#disk_tftest[@]}" -gt 0 ] && check_kind tftest "${disk_tftest[@]}"

for p in "${!want_kind[@]}"; do
	note "MISSING suite: $p is in the manifest but not on disk — moved or deleted without updating the manifest"
done

# --- 3. cross-check what hk actually schedules ------------------------
plan="$(cd "$ROOT" && hk check --all --plan --json 2>/dev/null)"
sched_bats="$(jq -r '(.steps[]|select(.name=="bats")|.fileCount) // 0' <<<"$plan")"
tt_status="$(jq -r '(.steps[]|select(.name=="tofu-test")|.status) // "absent"' <<<"$plan")"
tt_count="$(jq -r '(.steps[]|select(.name=="tofu-test")|.fileCount) // 0' <<<"$plan")"

[ "$sched_bats" = "${#disk_bats[@]}" ] ||
	note "hk schedules $sched_bats .bats files but disk has ${#disk_bats[@]} — the bats glob in hk.pkl is dropping a suite"

if [ "${#disk_tftest[@]}" -gt 0 ]; then
	[ "$tt_status" = included ] ||
		note "hk did not schedule the tofu-test step (status=$tt_status) while .tftest.hcl files exist"
	[ "$tt_count" -gt 0 ] ||
		note "hk scheduled tofu-test with 0 files while .tftest.hcl files exist — the tofu-test glob is broken"
fi

if [ "$fail" -eq 0 ]; then
	echo "check-coverage: ${#disk_bats[@]} bats + ${#disk_tftest[@]} tftest suites — disk, manifest and hk agree"
fi
exit "$fail"
