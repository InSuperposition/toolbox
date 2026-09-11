#!/usr/bin/env bats

# ci/scripts/registry-seed.sh — host-seeds the local zot with the digest-
# pinned base images a Dockerfile references, so an in-cluster BuildKit build
# never reaches docker.io / gcr.io (TODOS.md T7b1-followup, the OrbStack
# IPv6-egress defect). A fake `oras` on PATH captures the cp args, so
# these cases cover argument handling + the ref -> zot-path mapping without
# a network. The real copy is proven by `mise run frontend:seed` (recorded
# in TODOS.md T7b1-followup). `oras`, not `crane` (R1b-ii-c pre-plan): the
# darwin/Go toolchain gives `crane` no CA-file override at all; `oras
# --to-ca-file`/`--from-ca-file` are independently scoped per endpoint and
# confirmed digest-preserving against this script's own pins.

setup() {
	load helper
	SW="$CI_SCRIPTS/registry-seed.sh"

	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$FAKEBIN"
	cat >"$FAKEBIN/oras" <<-'SH'
		#!/usr/bin/env bash
		echo "oras $*"
		exit "${STUB_ORAS_RC:-0}"
	SH
	chmod +x "$FAKEBIN/oras"
	PATH="$FAKEBIN:$PATH"

	# zot-trust.sh's output — a fixture cert, not the real dev CA.
	export TOOLBOX_ZOT_CA="$BATS_TEST_TMPDIR/zot-ca.crt"
	printf -- '-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n' >"$TOOLBOX_ZOT_CA"

	DF="$BATS_TEST_TMPDIR/Dockerfile"
	cat >"$DF" <<-'EOF'
		# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
		FROM node:26-trixie-slim@sha256:c0753125a3789977aefe869cbebccf70e3cfd7ea84ca48547458f02e4f1d7146 AS deps
		RUN echo build
		FROM gcr.io/distroless/nodejs26-debian13:nonroot@sha256:10ec8cb93ef461563da50d4eb8dfac7d048783826825bf5b07510c2f34c14315 AS runtime
	EOF
}

@test "no argument -> exit 2 with usage" {
	run "$SW"
	[ "$status" -eq 2 ]
	[[ "$output" == *"usage:"* ]]
}

@test "missing Dockerfile -> exit 2" {
	run "$SW" "$BATS_TEST_TMPDIR/nope"
	[ "$status" -eq 2 ]
}

@test "missing zot CA -> exit 2, points at the trust task" {
	rm -f "$TOOLBOX_ZOT_CA"
	run "$SW" "$DF"
	[ "$status" -eq 2 ]
	[[ "$output" == *"local:zot:trust"* ]]
}

@test "Dockerfile with no digest-pinned image -> exit 3" {
	printf 'FROM alpine:3.20\n' >"$BATS_TEST_TMPDIR/plain"
	run "$SW" "$BATS_TEST_TMPDIR/plain"
	[ "$status" -eq 3 ]
}

@test "maps each FROM + syntax ref to a zot repo path, digest preserved" {
	run "$SW" "$DF" reg.example:5000
	[ "$status" -eq 0 ]
	# docker.io official image -> library/ prefix
	[[ "$output" == *"reg.example:5000/library/node:26-trixie-slim"* ]]
	# docker.io 2-segment (no host) -> kept as-is
	[[ "$output" == *"reg.example:5000/docker/dockerfile:1"* ]]
	# gcr.io -> host stripped
	[[ "$output" == *"reg.example:5000/distroless/nodejs26-debian13:nonroot"* ]]
	# the source ref carries its digest into `oras cp`
	[[ "$output" == *"@sha256:c0753125"* ]]
}

@test "defaults the registry to zot.zot.svc.cluster.local:5000" {
	run "$SW" "$DF"
	[ "$status" -eq 0 ]
	[[ "$output" == *"zot.zot.svc.cluster.local:5000/library/node"* ]]
}

@test "a failed copy -> exit 4, other copies still attempted" {
	STUB_ORAS_RC=1 run "$SW" "$DF"
	[ "$status" -eq 4 ]
	[[ "$output" == *"copy failed"* ]]
	# all three refs were attempted despite the first failing
	[ "$(grep -c 'oras cp' <<<"$output")" -eq 3 ]
}

@test "uses --to-ca-file (zot is HTTPS, T7c R1b-ii-c), never --insecure or --to-plain-http" {
	run "$SW" "$DF"
	[ "$status" -eq 0 ]
	[[ "$output" == *"--to-ca-file $TOOLBOX_ZOT_CA"* ]]
	[[ "$output" != *"--insecure"* ]]
	[[ "$output" != *"--to-plain-http"* ]]
}

@test "docker.io-implicit source refs are fully qualified for oras (crane defaulted these, oras does not)" {
	# Live-caught (2026-09-11): oras has no implicit docker.io default the
	# way `docker pull`/`crane` do. A bare "node:tag@sha256" errors "missing
	# registry or repository"; a 2-segment "docker/dockerfile:1@sha256"
	# resolves oras to host "docker" (a real DNS lookup failure). Both must
	# reach oras as an explicit `docker.io/...` ref.
	run "$SW" "$DF"
	[ "$status" -eq 0 ]
	[[ "$output" == *"oras cp docker.io/library/node:26-trixie-slim@sha256:c0753125"* ]]
	[[ "$output" == *"oras cp docker.io/docker/dockerfile:1@sha256:ecfaec9e"* ]]
}

@test "an already host-qualified source ref (gcr.io) passes through unchanged" {
	run "$SW" "$DF"
	[ "$status" -eq 0 ]
	[[ "$output" == *"oras cp gcr.io/distroless/nodejs26-debian13:nonroot@sha256:10ec8cb9"* ]]
	# never double-qualified
	[[ "$output" != *"docker.io/gcr.io"* ]]
}
