#!/usr/bin/env bats

# environments/local/zot/zot.yaml invariants. Static assertions only; the
# real in-cluster push / pull / Referrers proof rides with the first build
# Task that targets zot, the same way an earlier build-time spike proved
# buildkit's own push/pull path, not a lint.
#
# Catches a future regression: an un-pinned image, mTLS silently dropped,
# GC turned back on, or the exposure widened from ClusterIP to NodePort or
# LoadBalancer — `mise run check` goes red.

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

@test "the zot config requires a SPIFFE client cert (mTLS) for push, anonymous read stays open" {
	run grep -n '"mtls"' "$ZOT"
	[ "$status" -eq 0 ]
	run grep -n '"identityAttributes"' "$ZOT"
	[ "$status" -eq 0 ]
}

@test "the zot accessControl grants read/create/update to the registered ci-namespace identity" {
	run grep -nF 'spiffe://toolbox.local/ns/ci/sa/default' "$ZOT"
	[ "$status" -eq 0 ]
	# update matters because create alone only authorizes the first-ever
	# push to a given tag/repo — a CI re-run on an unchanged commit needs
	# update too, or its second push gets a 403.
	run grep -n '"actions": \["read", "create", "update"\]' "$ZOT"
	[ "$status" -eq 0 ]
	run grep -n '"defaultPolicy": \["read"\]' "$ZOT"
	[ "$status" -eq 0 ]
}

@test "the zot accessControl grants anonymousPolicy read (distinct from defaultPolicy — live-verified: zot's authn layer only treats a no-cert request as anonymous when anonymousPolicy is set, defaultPolicy alone 401s the readiness probe)" {
	run grep -n '"anonymousPolicy": \["read"\]' "$ZOT"
	[ "$status" -eq 0 ]
}

@test "GC is off (subsumes deleteUntagged: false — this store never deletes)" {
	run grep -nE '"gc":\s*false' "$ZOT"
	[ "$status" -eq 0 ]
}

@test "the Service is ClusterIP, never NodePort or LoadBalancer, since one in-cluster name and cert SAN set needs no host-exposed port" {
	run grep -nE 'type:\s*ClusterIP' "$ZOT"
	[ "$status" -eq 0 ]
	run grep -nE 'type:\s*NodePort' "$ZOT"
	[ "$status" -ne 0 ]
	run grep -nE 'type:\s*LoadBalancer' "$ZOT"
	[ "$status" -ne 0 ]
}

@test "HTTPS-only: http.tls block present, zot-tls secret mounted at /certs" {
	run grep -n '"tls"' "$ZOT"
	[ "$status" -eq 0 ]
	run grep -nE 'secretName:\s*zot-tls' "$ZOT"
	[ "$status" -eq 0 ]
}

@test "BOTH probes are HTTPS (a readiness-only fix means ready-then-killed)" {
	run bash -c "grep -c 'scheme: HTTPS' '$ZOT'"
	[ "$output" -eq 2 ]
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
