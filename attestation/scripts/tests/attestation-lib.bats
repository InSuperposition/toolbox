#!/usr/bin/env bats

# Pure-function coverage for the registry-classification helpers added in
# T7c R2 (attestation-sign.sh / attestation-verify.sh in-cluster-zot path).
# No network, no fixture registry — attestation_is_cluster_registry and
# attestation_cluster_ca_file are hostname/env logic only; their effect on
# the actual oras/cosign calls is exercised live (attestation-sign.bats /
# attestation-verify.bats cover the loopback --plain-http path unchanged;
# the CA-file path was live-verified against the real in-cluster zot, T7c
# R2 PR description).

setup() {
	SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	# shellcheck source=/dev/null
	. "$SCRIPTS/lib/attestation.sh"
	unset TOOLBOX_ZOT_HOST TOOLBOX_ZOT_CA
}

@test "the default zot host matches, everything else does not" {
	run attestation_is_cluster_registry "zot.zot.svc.cluster.local:5000"
	[ "$status" -eq 0 ]
	run attestation_is_cluster_registry "ghcr.io"
	[ "$status" -eq 1 ]
	run attestation_is_cluster_registry "127.0.0.1:12345"
	[ "$status" -eq 1 ]
	run attestation_is_cluster_registry ""
	[ "$status" -eq 1 ]
}

@test "TOOLBOX_ZOT_HOST overrides which host counts as the cluster registry" {
	TOOLBOX_ZOT_HOST="my-zot.example:5000" run attestation_is_cluster_registry "my-zot.example:5000"
	[ "$status" -eq 0 ]
	TOOLBOX_ZOT_HOST="my-zot.example:5000" run attestation_is_cluster_registry "zot.zot.svc.cluster.local:5000"
	[ "$status" -eq 1 ]
}

@test "the default CA file path is derived from the default zot host" {
	run attestation_cluster_ca_file
	[ "$status" -eq 0 ]
	[ "$output" = "$HOME/.docker/certs.d/zot.zot.svc.cluster.local:5000/ca.crt" ]
}

@test "TOOLBOX_ZOT_CA overrides the CA file path outright" {
	TOOLBOX_ZOT_CA="/tmp/some-other-ca.crt" run attestation_cluster_ca_file
	[ "$output" = "/tmp/some-other-ca.crt" ]
}

@test "TOOLBOX_ZOT_HOST alone (no TOOLBOX_ZOT_CA) changes the derived CA path" {
	TOOLBOX_ZOT_HOST="my-zot.example:5000" run attestation_cluster_ca_file
	[ "$output" = "$HOME/.docker/certs.d/my-zot.example:5000/ca.crt" ]
}
