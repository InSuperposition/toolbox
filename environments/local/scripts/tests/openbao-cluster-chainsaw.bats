#!/usr/bin/env bats

# environments/local/scripts/openbao-cluster-chainsaw.sh — the [k8s] skip
# gate. A fake kubectl on PATH drives the skip decision; these cover only
# that. The real end-to-end chainsaw run is the hk `chainsaw-openbao-cluster`
# step (skips in CI, runs against the live cluster locally) and the
# documented `mise run local:openbao-cluster:bootstrap` acceptance run.

setup() {
	load helper
	SW="$(toolbox_repo_root)/environments/local/scripts/openbao-cluster-chainsaw.sh"

	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$FAKEBIN"
	cat >"$FAKEBIN/kubectl" <<-'SH'
		#!/usr/bin/env bash
		case "$*" in
		*"config get-contexts -o name"*) printf '%s\n' ${STUB_CONTEXTS-orbstack}; exit 0 ;;
		*"cluster-info"*)                 exit "${STUB_CLUSTERINFO_RC:-0}" ;;
		*"get statefulset openbao"*)      exit "${STUB_STS_RC:-0}" ;;
		*) exit 0 ;;
		esac
	SH
	chmod +x "$FAKEBIN/kubectl"
	cat >"$FAKEBIN/chainsaw" <<-'SH'
		#!/usr/bin/env bash
		echo "fake chainsaw ran: $*"
	SH
	chmod +x "$FAKEBIN/chainsaw"
	PATH="$FAKEBIN:$PATH"
	export TOOLBOX_OPENBAO_CLUSTER_KUBE_CONTEXT=orbstack
}

@test "TOOLBOX_OPENBAO_CLUSTER_SKIP_CHAINSAW forces the skip path, exit 0" {
	TOOLBOX_OPENBAO_CLUSTER_SKIP_CHAINSAW=1 run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"skipping ([k8s] gate)"* ]]
}

@test "no reachable cluster -> skip, exit 0" {
	STUB_CLUSTERINFO_RC=1 run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"unreachable"* ]]
}

@test "context not in the kubeconfig -> skip, exit 0" {
	STUB_CONTEXTS="somethingelse" run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"kube-context"* ]]
}

@test "cluster up but in-cluster OpenBao not deployed -> skip naming the bootstrap task" {
	STUB_STS_RC=1 run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"local:openbao-cluster:bootstrap"* ]]
}

@test "cluster + StatefulSet present -> runs chainsaw" {
	run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"fake chainsaw ran"* ]]
	[[ "$output" == *"--test-dir"* ]]
}
