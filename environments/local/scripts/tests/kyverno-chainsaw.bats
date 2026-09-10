#!/usr/bin/env bats

# environments/local/scripts/kyverno-chainsaw.sh — the [k8s] skip gate. A
# fake kubectl on PATH drives the skip decision; these cover only that. The
# real end-to-end chainsaw run is the hk `chainsaw-kyverno` step (skips in
# CI, runs against the live cluster locally once the `kyverno-policy` Flux
# Kustomization has reconciled the ImageValidatingPolicy).

setup() {
	load helper
	SW="$(toolbox_repo_root)/environments/local/scripts/kyverno-chainsaw.sh"

	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$FAKEBIN"
	cat >"$FAKEBIN/kubectl" <<-'SH'
		#!/usr/bin/env bash
		case "$*" in
		*"config get-contexts -o name"*) printf '%s\n' ${STUB_CONTEXTS-orbstack}; exit 0 ;;
		*"cluster-info"*)                 exit "${STUB_CLUSTERINFO_RC:-0}" ;;
		*"get imagevalidatingpolicy frontend-approval"*) exit "${STUB_IVPOL_RC:-0}" ;;
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
	export TOOLBOX_KYVERNO_KUBE_CONTEXT=orbstack
}

@test "TOOLBOX_KYVERNO_SKIP_CHAINSAW forces the skip path, exit 0" {
	TOOLBOX_KYVERNO_SKIP_CHAINSAW=1 run "$SW"
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

@test "cluster up but the policy not reconciled -> skip naming the Kustomization" {
	STUB_IVPOL_RC=1 run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"kyverno-policy"* ]]
}

@test "cluster + policy present -> runs chainsaw" {
	run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"fake chainsaw ran"* ]]
	[[ "$output" == *"--test-dir"* ]]
	# the repo-root chainsaw config (namespace.fastDelete) is passed
	[[ "$output" == *"--config"* ]]
	[[ "$output" == *".chainsaw.yaml"* ]]
}
