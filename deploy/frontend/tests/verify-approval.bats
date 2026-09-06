#!/usr/bin/env bats

# The consume-side gate (verify-approval.sh / `mise run consume`) is the
# actual trust boundary — it never touches OpenBao, so it is fully testable
# with a local zot + a throwaway cosign key. Covers the
# docs/designs/digest-as-source-of-truth.md § Architecture consume path and
# its failure modes.

setup() {
	load helper
	FIX="$(mktemp -d)"
	SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
	start_registry "$FIX"
	make_key "$FIX"
	export TOOLBOX_APPROVAL_PUBKEY="$FIX/cosign.pub"
	IMAGE="$(make_image "$FIX")"
}

teardown() {
	load helper
	stop_registry "$FIX"
	rm -rf "$FIX"
}

sign() { # <verdict> -> echoes the attestation digest
	attestation_digest "$(run_approve "$IMAGE" "$1" "reason for $1")"
}

@test "a pinned approved attestation verifies (exit 0)" {
	att="$(sign approve)"
	run "$SCRIPTS/verify-approval.sh" "$IMAGE" "$att"
	[ "$status" -eq 0 ]
}

@test "a pinned rejected attestation is refused with 'verdict: rejected'" {
	att="$(sign reject)"
	run "$SCRIPTS/verify-approval.sh" "$IMAGE" "$att"
	[ "$status" -eq 1 ]
	[[ "$output" == *"verdict: rejected"* ]]
}

@test "selection model: an approval still verifies with a signed reject next to it" {
	approve_att="$(sign approve)"
	reject_att="$(sign reject)"
	[ -n "$reject_att" ]
	run "$SCRIPTS/verify-approval.sh" "$IMAGE" "$approve_att"
	[ "$status" -eq 0 ]
}

@test "wrong subject: an approval for another image is refused" {
	att="$(sign approve)"
	OTHER="$(make_image "$FIX")"
	run "$SCRIPTS/verify-approval.sh" "$OTHER" "$att"
	[ "$status" -eq 1 ]
	[[ "$output" == *"wrong subject"* ]]
}

@test "bad signature: verifying against a different public key is refused" {
	att="$(sign approve)"
	( cd "$FIX" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix other >/dev/null 2>&1 )
	TOOLBOX_APPROVAL_PUBKEY="$FIX/other.pub" run "$SCRIPTS/verify-approval.sh" "$IMAGE" "$att"
	[ "$status" -eq 1 ]
	[[ "$output" == *"bad signature"* ]]
}

@test "unknown attestation digest is retryable (exit 3), not a terminal failure" {
	run "$SCRIPTS/verify-approval.sh" "$IMAGE" "sha256:$(printf 'f%.0s' {1..64})"
	[ "$status" -eq 3 ]
	[[ "$output" == *"could not fetch attestation"* ]]
}

@test "a tag-only image reference is rejected (exit 2)" {
	run "$SCRIPTS/verify-approval.sh" "${REG}/img:build" "sha256:$(printf 'a%.0s' {1..64})"
	[ "$status" -eq 2 ]
	[[ "$output" == *"not a full digest reference"* ]]
}

@test "a non-sha256 attestation argument is rejected (exit 2)" {
	run "$SCRIPTS/verify-approval.sh" "$IMAGE" "not-a-digest"
	[ "$status" -eq 2 ]
}

@test "missing public key file is a usage error (exit 2)" {
	att="$(sign approve)"
	TOOLBOX_APPROVAL_PUBKEY="$FIX/nope.pub" run "$SCRIPTS/verify-approval.sh" "$IMAGE" "$att"
	[ "$status" -eq 2 ]
	[[ "$output" == *"public key not found"* ]]
}
