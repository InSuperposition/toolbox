#!/usr/bin/env bats

# environments/local/scripts/spire-bootstrap.sh — the one-time bridge
# that stands up SPIRE Server + Agent. The full bootstrap needs a real
# OrbStack cluster with OpenBao already up, so it is proven by the
# [k8s] chainsaw (environments/local/tests/spire/) and the manual
# `mise run local:spire:bootstrap` acceptance run, not here. These
# cases assert the fail-closed guards that run BEFORE any cluster call
# succeeds, without ever touching a cluster — same technique as
# openbao-bootstrap.bats: a kube-context that is not in the kubeconfig
# makes every case resolve deterministically without a stub.

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" \
		"environments/local/scripts/spire-bootstrap.sh" \
		"environments/local/scripts/spire-verify.sh" \
		"environments/local/spire"
	SW="$SCRATCH/environments/local/scripts/spire-bootstrap.sh"

	export TOOLBOX_SPIRE_KUBE_CONTEXT="toolbox-bats-nonexistent"
}

teardown() {
	cd /
	rm -rf "$SCRATCH"
}

@test "missing binary -> die" {
	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$FAKEBIN"
	for bin in kubectl tofu; do
		ln -s "$(command -v "$bin")" "$FAKEBIN/$bin"
	done
	# helm deliberately absent — PATH excludes mise's shim dir entirely,
	# keeping only /usr/bin:/bin (env, bash itself) + the symlinked pair.
	PATH="$FAKEBIN:/usr/bin:/bin" run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"helm not on PATH"* ]]
}

@test "nonexistent kube-context -> die naming orb start k8s" {
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unreachable"* ]]
	[[ "$output" == *"orb start k8s"* ]]
}

@test "shellcheck-clean" {
	run shellcheck "$SW"
	[ "$status" -eq 0 ]
}
