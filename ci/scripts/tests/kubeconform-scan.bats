#!/usr/bin/env bats

# ci/scripts/kubeconform-scan.sh — the static Tekton-manifest gate. Runs on a
# scratch copy of ci/ so a deliberately broken manifest can be asserted to
# fail (the guard must FAIL on bad input, not only pass on good).

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" "ci/tasks" "ci/runtime" "ci/scripts" "ci/tests/crd-schemas"
	: >"$SCRATCH/mise.toml"
	SW="$SCRATCH/ci/scripts/kubeconform-scan.sh"
}

teardown() {
	cd /
	rm -rf "$SCRATCH"
}

@test "passes on the committed manifests" {
	run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Invalid: 0"* ]]
}

@test "fails when a Task field is the wrong type" {
	# steps must be a list, not a string
	sed -i.bak 's/^  steps:/  steps: "not a list"\n_disabled:/' "$SCRATCH/ci/tasks/buildkit-build.yaml"
	run "$SW"
	[ "$status" -ne 0 ]
}

@test "fails on an unknown apiVersion" {
	sed -i.bak 's#tekton.dev/v1#tekton.dev/v0bogus#' "$SCRATCH/ci/tasks/buildkit-build.yaml"
	run "$SW"
	[ "$status" -ne 0 ]
}
