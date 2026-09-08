#!/usr/bin/env bats

# environments/local/zot/zot.yaml invariants — the interim local zot registry
# (TODOS.md T7b0). Static assertions only; the real in-cluster push / pull /
# Referrers proof rides with T7b1 (the first build Task that targets zot),
# the same way T7a proved buildkit in a spike, not a lint.
#
# Catches a future regression: an un-pinned image, an accidental auth block,
# GC turned back on, or the exposure widened from NodePort to LoadBalancer —
# `mise run check` goes red.

setup() {
	load helper
	ZOT="$(toolbox_repo_root)/environments/local/zot/zot.yaml"
	[ -f "$ZOT" ]
}

@test "zot image is pinned by digest" {
	run grep -nE 'image:\s*ghcr\.io/project-zot/zot-linux-arm64:v[0-9.]+@sha256:[0-9a-f]{64}$' "$ZOT"
	[ "$status" -eq 0 ]
}

@test "no un-pinned zot image reference" {
	run grep -nE 'image:\s*ghcr\.io/project-zot/[^@]*$' "$ZOT"
	[ "$status" -ne 0 ]
}

@test "the zot config has no auth block (credential-free is deliberate — guard against a half-applied one)" {
	run grep -n '"auth"' "$ZOT"
	[ "$status" -ne 0 ]
}

@test "GC is off (subsumes deleteUntagged: false for the interim store)" {
	run grep -nE '"gc":\s*false' "$ZOT"
	[ "$status" -eq 0 ]
}

@test "the Service is NodePort, never LoadBalancer (the exposure boundary is one host port)" {
	run grep -nE 'type:\s*NodePort' "$ZOT"
	[ "$status" -eq 0 ]
	run grep -nE 'type:\s*LoadBalancer' "$ZOT"
	[ "$status" -ne 0 ]
}

@test "the pod mounts no ServiceAccount token" {
	run grep -nE 'automountServiceAccountToken:\s*false' "$ZOT"
	[ "$status" -eq 0 ]
}

@test "the container runs unprivileged non-root" {
	run grep -nE 'runAsNonRoot:\s*true' "$ZOT"
	[ "$status" -eq 0 ]
	run grep -nE 'allowPrivilegeEscalation:\s*false' "$ZOT"
	[ "$status" -eq 0 ]
}
