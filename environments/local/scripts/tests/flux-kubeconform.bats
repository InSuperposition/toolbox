#!/usr/bin/env bats

# environments/local/scripts/flux-kubeconform.sh — the static Flux-CR schema
# gate. Runs on a scratch copy of environments/local/flux/ so a deliberately
# broken manifest can be asserted to fail (the guard must FAIL on bad input,
# not only pass on good).

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" "environments/local/flux" "environments/local/scripts/flux-kubeconform.sh"
	: >"$SCRATCH/mise.toml"
	SW="$SCRATCH/environments/local/scripts/flux-kubeconform.sh"
}

teardown() {
	cd /
	rm -rf "$SCRATCH"
}

@test "passes on the committed Flux CRs" {
	run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Invalid: 0"* ]]
	# flux-instance (1) + operator OCIRepository+HelmRelease (2) + zot-sync (1)
	# + ci-runtime (1) + ci-defs ci-tasks/ci-pipelines (2) + cert-manager
	# OCIRepository+HelmRelease (2) + cert-manager-pki Flux Kustomization (1)
	# + trust-manager OCIRepository+HelmRelease (2 — T7c R1b-i, ADR 0022)
	# + trust-manager-bundles Flux Kustomization (1 — T7c R1b-ii)
	# + kyverno OCIRepository+HelmRelease (2) + kyverno-policy Flux
	# Kustomization (1) + frontend OCIRepository + frontend-ns/frontend Flux
	# Kustomizations (3) = 19.
	[[ "$output" == *"Valid: 19"* ]]
}

@test "nothing skipped (the vendored Flux CRD schemas are all used)" {
	run "$SW"
	[[ "$output" == *"Skipped: 0"* ]]
}

@test "fails when a FluxInstance field is the wrong type" {
	# spec.distribution.version must be a string
	sed -i.bak 's/version: "2.9.5"/version: 295/' "$SCRATCH/environments/local/flux/flux-instance.yaml"
	run "$SW"
	[ "$status" -ne 0 ]
}

@test "fails when the zot Kustomization drops a required field" {
	# spec.prune is required on a Flux Kustomization
	sed -i.bak '/^  prune: true$/d' "$SCRATCH/environments/local/flux/zot-sync.yaml"
	run "$SW"
	[ "$status" -ne 0 ]
}
