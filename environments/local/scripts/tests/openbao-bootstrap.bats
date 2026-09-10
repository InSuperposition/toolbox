#!/usr/bin/env bats

# environments/local/scripts/openbao-bootstrap.sh — the one-time
# imperative bridge that moves / recovers the local OpenBao in the cluster
# (T7c Increment 4).
#
# The full migration needs an OrbStack cluster + Flux (+ optionally a live
# host daemon), so it is proven by the [k8s] chainsaw
# (environments/local/tests/openbao/) and the manual acceptance run
# in the script header, not here. These cases assert the SOURCE SELECTION
# and the fail-closed guards without ever touching a cluster: the host at
# TOOLBOX_OPENBAO_HOST_ADDR is a dead port and the kube-context does not
# exist, so every run resolves to "no host" and then either the disaster
# exit (no bundle) or the cluster-unreachable exit (a bundle is present).

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" \
		"environments/local/scripts/openbao-bootstrap.sh" \
		"environments/local/scripts/openbao-snapshot.sh" \
		"environments/local/scripts/openbao-verify.sh" \
		"environments/local/openbao"
	: >"$SCRATCH/mise.toml"
	SW="$SCRATCH/environments/local/scripts/openbao-bootstrap.sh"

	export TOOLBOX_OPENBAO_STATE_DIR="$SCRATCH/state"
	mkdir -p "$TOOLBOX_OPENBAO_STATE_DIR"
	# a dead port so "host reachable" is deterministically false even on a
	# dev box running the real daemon on 8200.
	export TOOLBOX_OPENBAO_HOST_ADDR="http://127.0.0.1:1"
	# a context that is not in the kubeconfig
	export TOOLBOX_OPENBAO_KUBE_CONTEXT="toolbox-bats-nonexistent"
}

teardown() {
	cd /
	rm -rf "$SCRATCH"
}

seed_bundle() {
	local snap="$TOOLBOX_OPENBAO_STATE_DIR/snapshots"
	mkdir -p "$snap"
	printf 'RAFT-SNAPSHOT-BYTES' >"$snap/latest.snap"
	printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' >"$snap/seal.key"
	printf 'hvs.fake-root-token' >"$snap/root.token"
	chmod 600 "$snap"/{seal.key,root.token}
}

@test "no host and no bundle -> the disaster exit naming the recovery runbook" {
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"no migration source"* ]]
	[[ "$output" == *"ADR 0016"* ]]
	[[ "$output" == *"resume signing"* ]]
	[[ "$output" == *"attestation:export-pubkey"* ]]
}

@test "a valid bundle carries source selection past the missing host" {
	seed_bundle
	run "$SW"
	[ "$status" -ne 0 ]
	# it did NOT die at source selection...
	[[ "$output" != *"no migration source"* ]]
	# ...it got to the cluster check and died there instead
	[[ "$output" == *"kube-context 'toolbox-bats-nonexistent' unreachable"* ]]
}

@test "source selection runs before any cluster call" {
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"no migration source"* ]]
	[[ "$output" != *"kube-context 'toolbox-bats-nonexistent' unreachable"* ]]
}

@test "a missing required binary fails closed" {
	seed_bundle
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

@test "the seal Secret is created from the bundle key file, never a literal or stdin" {
	# Codex #1 — the pod auto-unseals from this Secret; its bytes must be the
	# restore bundle's 0600 seal key, delivered --from-file (never state,
	# never a helm value, never --from-literal / a piped heredoc).
	run grep -Eq 'create secret generic openbao-seal' "$SW"
	[ "$status" -eq 0 ]
	run grep -Eq -- '--from-file=seal\.key="\$SNAP_DIR/seal\.key"' "$SW"
	[ "$status" -eq 0 ]
	run bash -c "grep -vE '^[[:space:]]*#' '$SW' | grep -Eq 'openbao-seal.*--from-literal'"
	[ "$status" -ne 0 ]
}

@test "the approval-key assertion reads the endpoint directly, never via a nested \`mise run\`" {
	# T7c Increment 4 eng review, Codex #4: `mise run` re-applies mise.toml's
	# [env], pinning VAULT_ADDR at the host loopback — so an assertion routed
	# through `mise run attestation:export-pubkey` verifies the host, not the
	# migrated cluster. assert_key_preserved must call cosign directly.
	# the bug was `(cd "$root" && mise run attestation:export-pubkey)` — guard
	# the two invocation shapes, not the backtick-quoted hint in a die message
	run grep -Eq '&&[[:space:]]*mise run attestation' "$SW"
	[ "$status" -ne 0 ]
	run grep -Eq '^[[:space:]]*mise run attestation' "$SW"
	[ "$status" -ne 0 ]
	run grep -Eq 'cosign public-key --key openbao://approval-key' "$SW"
	[ "$status" -eq 0 ]
}

@test "shellcheck-clean" {
	run shellcheck "$SW"
	[ "$status" -eq 0 ]
}
