#!/usr/bin/env bats

# environments/local/scripts/openbao-cluster-bootstrap.sh — the one-time
# imperative bridge that moves the local OpenBao into the cluster (T7c
# Increment 4b).
#
# The full migration needs an OrbStack cluster + a live host daemon + Flux,
# so it is proven by the [k8s] chainsaw
# (environments/local/tests/openbao-cluster/) and a manual acceptance run,
# not here. These cases assert the guard FAILS CLOSED at each precondition —
# a missing seal key, an unreachable host daemon, an unreachable cluster —
# without ever touching a cluster.

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" \
		"environments/local/scripts/openbao-cluster-bootstrap.sh" \
		"environments/local/scripts/openbao-snapshot.sh" \
		"environments/local/scripts/openbao-cluster-verify.sh" \
		"environments/local/openbao-cluster"
	: >"$SCRATCH/mise.toml"
	SW="$SCRATCH/environments/local/scripts/openbao-cluster-bootstrap.sh"

	export TOOLBOX_OPENBAO_STATE_DIR="$SCRATCH/state"
	mkdir -p "$TOOLBOX_OPENBAO_STATE_DIR"
	# a dead port so the host-daemon precondition is deterministic even on a
	# dev box that happens to be running the real daemon on 8200.
	export TOOLBOX_OPENBAO_HOST_ADDR="http://127.0.0.1:1"
	# a context that is not in the kubeconfig
	export TOOLBOX_OPENBAO_CLUSTER_KUBE_CONTEXT="toolbox-bats-nonexistent"
}

teardown() {
	cd /
	rm -rf "$SCRATCH"
}

seed_host_secrets() {
	printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' >"$TOOLBOX_OPENBAO_STATE_DIR/seal.key"
	printf 'hvs.fake-root-token' >"$TOOLBOX_OPENBAO_STATE_DIR/root.token"
	chmod 600 "$TOOLBOX_OPENBAO_STATE_DIR"/{seal.key,root.token}
}

@test "fails when \$STATE_DIR/seal.key is missing" {
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"seal.key missing"* ]]
	[[ "$output" == *"local:openbao:bootstrap"* ]]
}

@test "fails when \$STATE_DIR/root.token is missing" {
	printf 'x' >"$TOOLBOX_OPENBAO_STATE_DIR/seal.key"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"root.token missing"* ]]
}

@test "fails when the host daemon is unreachable" {
	seed_host_secrets
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"host OpenBao at http://127.0.0.1:1 is not initialised"* ]]
}

@test "the host-daemon check runs before any cluster call" {
	seed_host_secrets
	run "$SW"
	[ "$status" -ne 0 ]
	# it must not have reached the kube-context check
	[[ "$output" != *"kube-context 'toolbox-bats-nonexistent' unreachable"* ]]
}

@test "a missing required binary fails closed" {
	seed_host_secrets
	# a PATH with only bash/coreutils-ish essentials, no bao
	local stub="$SCRATCH/stubbin"
	mkdir -p "$stub"
	for b in bash env cat sed grep dirname cd; do
		ln -sf "$(command -v "$b")" "$stub/$b" 2>/dev/null || true
	done
	run env PATH="$stub" "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not on PATH"* ]]
}

@test "the approval-key assertion reads the endpoint directly, never via a nested \`mise run\`" {
	# T7c Increment 4 eng review, Codex #4: `mise run` re-applies mise.toml's
	# [env], pinning VAULT_ADDR at the host loopback — so an assertion routed
	# through `mise run attestation:export-pubkey` verifies the host, not the
	# migrated cluster. assert_key_preserved must call cosign directly.
	# no non-comment line invokes the attestation mise task
	run bash -c "grep -vE '^[[:space:]]*#' '$SW' | grep -q 'mise run attestation'"
	[ "$status" -ne 0 ]
	run grep -Eq 'cosign public-key --key openbao://approval-key' "$SW"
	[ "$status" -eq 0 ]
}

@test "shellcheck-clean" {
	run shellcheck "$SW"
	[ "$status" -eq 0 ]
}
