#!/usr/bin/env bats

# attestation-verify.sh — the consumer-side gate, the actual trust boundary.
# It never touches OpenBao, so it is fully testable with a local zot + a
# throwaway cosign key. Covers the docs/designs/digest-as-source-of-truth.md
# § Architecture verify path and its failure modes.

setup() {
	load helper
	FIX="$(mktemp -d)"
	SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
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
	attestation_digest "$(run_sign "$IMAGE" "$1" "reason for $1")"
}

@test "a pinned approved attestation verifies (exit 0)" {
	att="$(sign approve)"
	run "$SCRIPTS/attestation-verify.sh" "$IMAGE" "$att"
	[ "$status" -eq 0 ]
}

@test "a pinned rejected attestation is refused with 'verdict: rejected'" {
	att="$(sign reject)"
	run "$SCRIPTS/attestation-verify.sh" "$IMAGE" "$att"
	[ "$status" -eq 1 ]
	[[ "$output" == *"verdict: rejected"* ]]
}

@test "selection model: an approval still verifies with a signed reject next to it" {
	approve_att="$(sign approve)"
	reject_att="$(sign reject)"
	[ -n "$reject_att" ]
	run "$SCRIPTS/attestation-verify.sh" "$IMAGE" "$approve_att"
	[ "$status" -eq 0 ]
}

# cosign's own claim check (signature + subject + predicate type, one call)
# is a single terminal "attestation verification failed" — the script no
# longer parses cosign's unversioned stderr to sub-classify. These three
# cases prove each of those checks still fires; the verdict-rejected case
# above is the one distinct message (it comes from the CUE schema, not cosign).

@test "wrong subject: an approval for another image is refused (exit 1)" {
	att="$(sign approve)"
	OTHER="$(make_image "$FIX")"
	run "$SCRIPTS/attestation-verify.sh" "$OTHER" "$att"
	[ "$status" -eq 1 ]
	[[ "$output" == *"attestation verification failed"* ]]
}

@test "bad signature: verifying against a different public key is refused (exit 1)" {
	att="$(sign approve)"
	( cd "$FIX" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix other >/dev/null 2>&1 )
	TOOLBOX_APPROVAL_PUBKEY="$FIX/other.pub" run "$SCRIPTS/attestation-verify.sh" "$IMAGE" "$att"
	[ "$status" -eq 1 ]
	[[ "$output" == *"attestation verification failed"* ]]
}

@test "wrong predicate type: a validly-signed non-approval attestation is refused (exit 1)" {
	# sign the image with a DIFFERENT predicate type — cosign's --type check
	# must still catch it (Codex: don't lose the predicate-type binding).
	jq -n --arg d "sha256:${IMAGE##*@sha256:}" \
		'{schemaVersion:1, digest:$d, verdict:"approved", reason:"x",
		  approvedBy:"bats", approvedAt:"2026-01-01T00:00:00Z",
		  scanReportRef:"sha256:0000000000000000000000000000000000000000000000000000000000000000"}' \
		>"$FIX/pred.json"
	COSIGN_PASSWORD="" cosign attest --predicate "$FIX/pred.json" \
		--type "https://example.com/not-an-approval/v1" \
		--key "$FIX/cosign.key" --use-signing-config=false --tlog-upload=false \
		"$IMAGE" >/dev/null 2>&1
	wrong="$(oras discover --plain-http --format json "$IMAGE" | jq -r '
		[.referrers[] | select(.artifactType == "application/vnd.dev.sigstore.bundle.v0.3+json")] | last | .digest')"
	run "$SCRIPTS/attestation-verify.sh" "$IMAGE" "$wrong"
	[ "$status" -eq 1 ]
	[[ "$output" == *"attestation verification failed"* ]]
}

@test "a post-sign-tampered statement fails the signature check (exit 1)" {
	att="$(sign approve)"
	mf="$(oras manifest fetch --plain-http "${IMAGE%@*}@${att}")"
	layer="$(printf '%s' "$mf" | jq -r '.layers[0].digest')"
	oras blob fetch --plain-http --output "$FIX/good.json" "${IMAGE%@*}@${layer}"
	# decode the DSSE payload, change one field, re-encode — the signature
	# (over the ORIGINAL payload) no longer matches.
	tampered="$(jq -r '.dsseEnvelope.payload' "$FIX/good.json" | base64 -d \
		| jq -c '.predicate.reason = "TAMPERED"' | base64 | tr -d '\n')"
	jq --arg p "$tampered" '.dsseEnvelope.payload = $p' "$FIX/good.json" >"$FIX/bad.json"
	bad="$(cd "$FIX" && oras attach --plain-http \
		--artifact-type application/vnd.dev.sigstore.bundle.v0.3+json \
		--format go-template --template '{{.digest}}' \
		"$IMAGE" "bad.json:application/vnd.dev.sigstore.bundle.v0.3+json" 2>/dev/null)"
	run "$SCRIPTS/attestation-verify.sh" "$IMAGE" "$bad"
	[ "$status" -eq 1 ]
	[[ "$output" == *"attestation verification failed"* ]]
}

@test "unknown attestation digest is retryable (exit 3), not a terminal failure" {
	run "$SCRIPTS/attestation-verify.sh" "$IMAGE" "sha256:$(printf 'f%.0s' {1..64})"
	[ "$status" -eq 3 ]
	[[ "$output" == *"could not fetch attestation"* ]]
}

@test "a tag-only image reference is rejected (exit 2)" {
	run "$SCRIPTS/attestation-verify.sh" "${REG}/img:build" "sha256:$(printf 'a%.0s' {1..64})"
	[ "$status" -eq 2 ]
	[[ "$output" == *"not a full digest reference"* ]]
}

@test "a non-sha256 attestation argument is rejected (exit 2)" {
	run "$SCRIPTS/attestation-verify.sh" "$IMAGE" "not-a-digest"
	[ "$status" -eq 2 ]
}

@test "missing public key file is a usage error (exit 2)" {
	att="$(sign approve)"
	TOOLBOX_APPROVAL_PUBKEY="$FIX/nope.pub" run "$SCRIPTS/attestation-verify.sh" "$IMAGE" "$att"
	[ "$status" -eq 2 ]
	[[ "$output" == *"public key not found"* ]]
}
