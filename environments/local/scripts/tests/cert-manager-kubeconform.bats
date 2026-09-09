#!/usr/bin/env bats

# environments/local/scripts/cert-manager-kubeconform.sh — the static
# schema gate for the dev-PKI CRs (T7c Increment 4). Runs on a scratch copy
# so a deliberately broken manifest can be asserted to fail (the guard must
# FAIL on bad input, not only pass on good).

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" \
		"environments/local/cert-manager" \
		"environments/local/scripts/cert-manager-kubeconform.sh"
	: >"$SCRATCH/mise.toml"
	SW="$SCRATCH/environments/local/scripts/cert-manager-kubeconform.sh"
}

teardown() {
	cd /
	rm -rf "$SCRATCH"
}

@test "passes on the committed PKI CRs" {
	run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Invalid: 0"* ]]
	# selfSigned ClusterIssuer + CA Certificate + CA ClusterIssuer + openbao-tls leaf
	[[ "$output" == *"Valid: 4"* ]]
}

@test "the vendored cert-manager CRD schemas are actually used (nothing skipped)" {
	run "$SW"
	[[ "$output" == *"Skipped: 0"* ]]
}

@test "fails when a Certificate drops its required issuerRef" {
	sed -i.bak '/^  issuerRef:$/,/    group: cert-manager.io$/d' "$SCRATCH/environments/local/cert-manager/issuers.yaml"
	run "$SW"
	[ "$status" -ne 0 ]
}

@test "fails on an unknown cert-manager apiVersion" {
	sed -i.bak 's|cert-manager.io/v1|cert-manager.io/v99|' "$SCRATCH/environments/local/cert-manager/issuers.yaml"
	run "$SW"
	[ "$status" -ne 0 ]
}
