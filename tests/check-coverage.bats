#!/usr/bin/env bats

# Mutation tests for tests/check-coverage.sh (F5): the guard must FAIL when
# the manifest and the tree disagree, not just pass when they happen to
# match. Each case points the script at a deliberately broken copy of the
# manifest and asserts a non-zero exit naming the affected suite.

setup() {
	ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	MANIFEST="$ROOT/tests/manifest.txt"
	BROKEN="$(mktemp)"
}

teardown() {
	rm -f "$BROKEN"
}

@test "passes against the real manifest" {
	run "$ROOT/tests/check-coverage.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"disk, manifest and hk agree"* ]]
}

@test "fails when a manifest entry is dropped (a suite it can no longer see)" {
	grep -v 'attestation-sign.bats' "$MANIFEST" >"$BROKEN"
	run "$ROOT/tests/check-coverage.sh" "$BROKEN"
	[ "$status" -ne 0 ]
	[[ "$output" == *"attestation-sign.bats"* ]]
}

@test "fails when a manifest case count no longer matches the suite" {
	sed 's/\(attestation-sign\.bats\)  *[0-9][0-9]*/\1 999/' "$MANIFEST" >"$BROKEN"
	run "$ROOT/tests/check-coverage.sh" "$BROKEN"
	[ "$status" -ne 0 ]
	[[ "$output" == *"CASE COUNT drift"* ]]
	[[ "$output" == *"attestation-sign.bats"* ]]
}
