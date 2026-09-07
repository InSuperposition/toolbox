#!/usr/bin/env bats

# ci/scripts/ci-chainsaw.sh — the [k8s] gate. The skip paths run anywhere
# (no cluster); the real chainsaw run is [k8s]-gated on a live orbstack +
# Tekton and asserts the whole wiring end to end.

setup() {
	load helper
	fakebin_setup
	export TOOLBOX_CI_KUBE_CONTEXT=orbstack
}

@test "TOOLBOX_CI_SKIP_CHAINSAW forces the skip path, exit 0" {
	TOOLBOX_CI_SKIP_CHAINSAW=1 run "$CI_SCRIPTS/ci-chainsaw.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"skipping ([k8s] gate)"* ]]
}

@test "no reachable cluster -> skip, exit 0" {
	STUB_KUBECTL_CLUSTERINFO_RC=1 run "$CI_SCRIPTS/ci-chainsaw.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no reachable"* ]]
}

@test "cluster up but Tekton absent -> skip naming local:tekton:install" {
	STUB_KUBECTL_TEKTON_RC=1 run "$CI_SCRIPTS/ci-chainsaw.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"local:tekton:install"* ]]
}

@test "[k8s] against a live orbstack + Tekton: chainsaw passes" {
	k8s_available || skip "no orbstack cluster with Tekton"
	run "$CI_SCRIPTS/ci-chainsaw.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS"* ]] || [[ "$output" == *"Passed  tests 1"* ]]
}
