#!/usr/bin/env bats

# environments/local/scripts/flux-chainsaw.sh — the [k8s] skip gate and the
# per-subdir gate loop. A fake kubectl + a fake chainsaw on PATH drive the
# decisions; these cover only which subdirs get selected. The real
# end-to-end chainsaw run is the hk `chainsaw` step itself
# (`./environments/local/scripts/flux-chainsaw.sh` — skips in CI, runs against
# the live cluster locally) and the documented `mise run local:flux:bootstrap`
# acceptance run (PR #19).

setup() {
	load helper
	SW="$(toolbox_repo_root)/environments/local/scripts/flux-chainsaw.sh"

	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$FAKEBIN"
	cat >"$FAKEBIN/kubectl" <<-'SH'
		#!/usr/bin/env bash
		case "$*" in
		*"config get-contexts -o name"*) printf '%s\n' ${STUB_CONTEXTS-orbstack}; exit 0 ;;
		*"cluster-info"*)                 exit "${STUB_CLUSTERINFO_RC:-0}" ;;
		*"get fluxinstance flux"*)        exit "${STUB_FLUXINSTANCE_RC:-0}" ;;
		*"get kustomization.kustomize.toolkit.fluxcd.io ci-runtime"*) exit "${STUB_CIRUNTIME_RC:-0}" ;;
		*) exit 0 ;;
		esac
	SH
	chmod +x "$FAKEBIN/kubectl"

	# Fake chainsaw: record its argv so a test can assert which --test-dir
	# entries the loop selected, then exit 0.
	cat >"$FAKEBIN/chainsaw" <<-SH
		#!/usr/bin/env bash
		printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/chainsaw.args"
		exit 0
	SH
	chmod +x "$FAKEBIN/chainsaw"

	PATH="$FAKEBIN:$PATH"
	export TOOLBOX_FLUX_KUBE_CONTEXT=orbstack
}

@test "TOOLBOX_FLUX_SKIP_CHAINSAW forces the skip path, exit 0" {
	TOOLBOX_FLUX_SKIP_CHAINSAW=1 run "$SW"
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

@test "cluster up but Flux not bootstrapped -> skip naming local:flux:bootstrap" {
	STUB_FLUXINSTANCE_RC=1 run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"local:flux:bootstrap"* ]]
}

@test "flux-reconcile + trust-manager-reconcile always selected (no probe)" {
	run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"+ flux-reconcile"* ]]
	[[ "$output" == *"+ trust-manager-reconcile"* ]]
	grep -qF "flux-reconcile" "$BATS_TEST_TMPDIR/chainsaw.args"
	grep -qF "trust-manager-reconcile" "$BATS_TEST_TMPDIR/chainsaw.args"
}

@test "ci-reconcile skipped when the ci-runtime Kustomization is absent" {
	STUB_CIRUNTIME_RC=1 run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"- ci-reconcile (gate probe negative"* ]]
	! grep -qF "ci-reconcile" "$BATS_TEST_TMPDIR/chainsaw.args"
}

@test "ci-reconcile selected when the ci-runtime Kustomization is present" {
	STUB_CIRUNTIME_RC=0 run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"+ ci-reconcile"* ]]
	grep -qF "ci-reconcile" "$BATS_TEST_TMPDIR/chainsaw.args"
}
