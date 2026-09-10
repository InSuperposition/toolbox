#!/usr/bin/env bats

# environments/local/scripts/kyverno-kubeconform.sh — the static schema gate
# for the Kyverno ImageValidatingPolicy + generated approval-pubkey
# ConfigMap (Plan B K1). Runs on a scratch copy so a deliberately broken
# manifest can be asserted to fail (the guard must FAIL on bad input, not
# only pass on good). The scratch copy includes attestation/cosign-approval.pub
# because the configMapGenerator reads it via `../../../`.

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" \
		"environments/local/kyverno" \
		"environments/local/scripts/kyverno-kubeconform.sh" \
		"attestation/cosign-approval.pub"
	: >"$SCRATCH/mise.toml"
	SW="$SCRATCH/environments/local/scripts/kyverno-kubeconform.sh"
}

teardown() {
	cd /
	rm -rf "$SCRATCH"
}

@test "passes on the committed policy + ConfigMap" {
	run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Invalid: 0"* ]]
	# the ImageValidatingPolicy + the generated approval-pubkey ConfigMap
	[[ "$output" == *"Valid: 2"* ]]
}

@test "the vendored ImageValidatingPolicy CRD schema is actually used (nothing skipped)" {
	run "$SW"
	[[ "$output" == *"Skipped: 0"* ]]
}

@test "fails when the policy drops its required validations" {
	sed -i.bak '/^  validations:$/,$d' "$SCRATCH/environments/local/kyverno/imagevalidatingpolicy.yaml"
	run "$SW"
	[ "$status" -ne 0 ]
}

@test "fails on an unknown policies.kyverno.io apiVersion" {
	sed -i.bak 's|policies.kyverno.io/v1|policies.kyverno.io/v99|' "$SCRATCH/environments/local/kyverno/imagevalidatingpolicy.yaml"
	run "$SW"
	[ "$status" -ne 0 ]
}

@test "fails when the pubkey the configMapGenerator reads is gone" {
	rm "$SCRATCH/attestation/cosign-approval.pub"
	run "$SW"
	[ "$status" -ne 0 ]
}
