#!/usr/bin/env bats

# ci/scripts/ci-chainsaw.sh — the [k8s] skip gate. Every case runs a fake
# kubectl/tkn (helper.bash fakebin_setup), so these cover only the skip
# decision. The real end-to-end chainsaw run is the hk `chainsaw` step
# itself (`./ci/scripts/ci-chainsaw.sh` — skips in CI, runs against the
# live cluster locally) and `mise run ci:taskrun`.

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
