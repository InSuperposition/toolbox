#!/usr/bin/env bats

# attestation-sign.sh matrix. The signing paths use a local cosign key via
# the TOOLBOX_APPROVE_KEY seam (no OpenBao — the openbao:// KMS leg is proved
# separately). The OpenBao-preflight path is exercised against a dead
# address. Covers docs/designs/digest-as-source-of-truth.md § Architecture
# (the sign path) and its failure modes.

setup_file() {
	load helper
	export FIX_FILE="$(mktemp -d)"
	export SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	start_registry "$FIX_FILE"
	export REG
	make_key "$FIX_FILE"
}

teardown_file() {
	load helper
	stop_registry "$FIX_FILE"
	rm -rf "$FIX_FILE"
}

setup() {
	load helper
	FIX="$FIX_FILE"
	export TOOLBOX_APPROVAL_PUBKEY="$FIX/cosign.pub"
	IMAGE="$(make_image "$FIX")"
}

@test "no argument is a usage error (exit 2)" {
	TOOLBOX_APPROVE_KEY="$FIX/cosign.key" run "$SCRIPTS/attestation-sign.sh"
	[ "$status" -eq 2 ]
	[[ "$output" == *"usage:"* ]]
}

@test "a tag-only reference is rejected — a tag is mutable (exit 2)" {
	TOOLBOX_APPROVE_KEY="$FIX/cosign.key" run "$SCRIPTS/attestation-sign.sh" "${REG}/img:build"
	[ "$status" -eq 2 ]
	[[ "$output" == *"not a full digest reference"* ]]
}

@test "OpenBao unreachable => exit 3 with the 'mise run local:openbao:start' hint" {
	# no TOOLBOX_APPROVE_KEY => the real openbao-preflight runs; point it at a dead port
	VAULT_ADDR="http://127.0.0.1:1" run "$SCRIPTS/attestation-sign.sh" "$IMAGE"
	[ "$status" -eq 3 ]
	[[ "$output" == *"cannot reach OpenBao"* ]]
	[[ "$output" == *"mise run local:openbao:start"* ]]
}

@test "missing build evidence => exit 4, no attestation" {
	BARE="$(make_bare_image "$FIX")"
	printf 'approve\nx\n' >"$FIX/answers"
	TOOLBOX_APPROVE_KEY="$FIX/cosign.key" COSIGN_PASSWORD="" run "$SCRIPTS/attestation-sign.sh" "$BARE" <"$FIX/answers"
	[ "$status" -eq 4 ]
	[[ "$output" == *"evidence missing"* ]]
}

@test "EOF at the prompt writes NO attestation (exit 1)" {
	TOOLBOX_APPROVE_KEY="$FIX/cosign.key" COSIGN_PASSWORD="" run "$SCRIPTS/attestation-sign.sh" "$IMAGE" </dev/null
	[ "$status" -eq 1 ]
	[[ "$output" == *"aborted"* ]]
	run oras discover --plain-http --format json "$IMAGE"
	[ "$(echo "$output" | jq '[.referrers[] | select(.artifactType == "application/vnd.dev.sigstore.bundle.v0.3+json")] | length')" -eq 0 ]
}

@test "an empty verdict line aborts, no attestation (exit 1)" {
	printf '\n' >"$FIX/answers"
	TOOLBOX_APPROVE_KEY="$FIX/cosign.key" COSIGN_PASSWORD="" run "$SCRIPTS/attestation-sign.sh" "$IMAGE" <"$FIX/answers"
	[ "$status" -eq 1 ]
}

@test "an empty reason aborts, no attestation (exit 1)" {
	printf 'approve\n\n' >"$FIX/answers"
	TOOLBOX_APPROVE_KEY="$FIX/cosign.key" COSIGN_PASSWORD="" run "$SCRIPTS/attestation-sign.sh" "$IMAGE" <"$FIX/answers"
	[ "$status" -eq 1 ]
	[[ "$output" == *"reason is required"* ]]
}

@test "approve: signs, reads back, prints the attestation digest" {
	out="$(run_sign "$IMAGE" approve "evidence clean")"
	[[ "$out" == *"APPROVED"* ]]
	att="$(attestation_digest "$out")"
	[[ "$att" == sha256:* ]]
	# the printed digest is a real, discoverable referrer of our type
	run oras manifest fetch --plain-http "${IMAGE%@*}@${att}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"insuperposition.github.io/toolbox/attestations/approval/v1"* ]]
}

@test "reject: still writes a signed record (never silent)" {
	out="$(run_sign "$IMAGE" reject "CVE too risky")"
	[[ "$out" == *"REJECTED"* ]]
	att="$(attestation_digest "$out")"
	run "$SCRIPTS/attestation-verify.sh" "$IMAGE" "$att"
	[ "$status" -eq 1 ]
	[[ "$output" == *"verdict: rejected"* ]]
}

@test "the signed predicate carries the scan-report referrer digest" {
	out="$(run_sign "$IMAGE" approve "clean")"
	att="$(attestation_digest "$out")"
	layer="$(oras manifest fetch --plain-http "${IMAGE%@*}@${att}" | jq -r '.layers[0].digest')"
	oras blob fetch --plain-http --output "$FIX/b.json" "${IMAGE%@*}@${layer}"
	scanref="$(jq -r '.dsseEnvelope.payload' "$FIX/b.json" | base64 -d | jq -r '.predicate.scanReportRef')"
	[[ "$scanref" == sha256:* ]]
}
