#!/usr/bin/env bats

# environments/local/scripts/flux-bootstrap.sh — the one-time bridge that
# installs flux-operator. It MUST cosign-verify the PINNED chart digest
# before `helm`, MUST install a digest (never a tag), and MUST thread one
# kube-context through every call. Fake `cosign` / `helm` / `kubectl` on
# PATH cover the decision logic without a cluster; the real install is the
# documented live `mise run local:flux:bootstrap` acceptance run (PR #<1a>).

setup() {
	load helper
	SW="$(toolbox_repo_root)/environments/local/scripts/flux-bootstrap.sh"

	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$FAKEBIN"
	CALLS="$BATS_TEST_TMPDIR/calls.log"

	cat >"$FAKEBIN/kubectl" <<-SH
		#!/usr/bin/env bash
		echo "kubectl \$*" >>"$CALLS"
		case "\$*" in
		  *"cluster-info"*) exit "\${STUB_KUBECTL_CLUSTERINFO_RC:-0}" ;;
		esac
		exit 0
	SH
	cat >"$FAKEBIN/cosign" <<-SH
		#!/usr/bin/env bash
		echo "cosign \$*" >>"$CALLS"
		exit "\${STUB_COSIGN_RC:-0}"
	SH
	cat >"$FAKEBIN/helm" <<-SH
		#!/usr/bin/env bash
		echo "helm \$*" >>"$CALLS"
		exit "\${STUB_HELM_RC:-0}"
	SH
	chmod +x "$FAKEBIN"/kubectl "$FAKEBIN"/cosign "$FAKEBIN"/helm
	PATH="$FAKEBIN:$PATH"

	LOCK="$BATS_TEST_TMPDIR/flux-operator.lock"
	cat >"$LOCK" <<-EOF
		version=0.59.0
		chart_digest=sha256:ae962f87e04301c61aeb41698146027ba4c2e4b4157d4c08fb4a4e335be9aa42
		operator_image_digest=sha256:29421fe9a49a533ac99a5b7779e1a5fffa3227b16ddfcefe1e3b14e5c20a1767
		manifests_digest=sha256:79681844844b24ff9e7fafc3edf7ddab886268b0ea51ce3ca8a5bd8bb7b40fe2
		cosign_issuer=https://token.actions.githubusercontent.com
		cosign_identity_regexp=^https://github\.com/controlplaneio-fluxcd/charts/.*\$
	EOF
	export TOOLBOX_FLUX_LOCK="$LOCK"
	export TOOLBOX_FLUX_KUBE_CONTEXT="testctx"
}

@test "missing lock file -> exit 1, nothing installed" {
	export TOOLBOX_FLUX_LOCK="$BATS_TEST_TMPDIR/nope.lock"
	run "$SW"
	[ "$status" -eq 1 ]
	[[ "$output" == *"lock file not found"* ]]
	[ ! -f "$CALLS" ]
}

@test "malformed chart_digest -> exit 1 before cosign" {
	sed -i.bak 's/^chart_digest=.*/chart_digest=not-a-digest/' "$LOCK"
	run "$SW"
	[ "$status" -eq 1 ]
	[[ "$output" == *"chart_digest is not sha256"* ]]
	run grep -c cosign "$CALLS"
	[ "$output" = "0" ] || [ ! -f "$CALLS" ]
}

@test "cluster unreachable -> exit 1 before cosign + helm" {
	STUB_KUBECTL_CLUSTERINFO_RC=1 run "$SW"
	[ "$status" -eq 1 ]
	[[ "$output" == *"unreachable"* ]]
	run grep -cE 'cosign|helm ' "$CALLS"
	[ "$output" = "0" ]
}

@test "cosign verify fails -> exit 1, helm never runs" {
	STUB_COSIGN_RC=1 run "$SW"
	[ "$status" -eq 1 ]
	[[ "$output" == *"cosign verify failed"* ]]
	run grep -c 'helm upgrade' "$CALLS"
	[ "$output" = "0" ]
}

@test "happy path: installs the chart DIGEST with the pinned context, applies + patches the FluxInstance" {
	run "$SW"
	[ "$status" -eq 0 ]
	grep -q 'helm upgrade --install flux-operator oci://.*@sha256:ae962f87' "$CALLS"
	grep -q -- '--kube-context testctx' "$CALLS"
	grep -q -- '--set image.tag=v0.59.0@sha256:29421fe9' "$CALLS"
	grep -q 'apply -f .*/flux-instance.yaml' "$CALLS"
	grep -q 'patch fluxinstance flux .*refs/heads/main' "$CALLS"
	# never a bare tag install
	run grep -c 'helm upgrade --install flux-operator oci://[^@]*$' "$CALLS"
	[ "$output" = "0" ]
}

@test "TOOLBOX_FLUX_SYNC_REF is threaded into the sync-ref patch" {
	TOOLBOX_FLUX_SYNC_REF="refs/heads/t7c-flux-bootstrap" run "$SW"
	[ "$status" -eq 0 ]
	grep -q 'patch fluxinstance flux .*refs/heads/t7c-flux-bootstrap' "$CALLS"
}
