#!/usr/bin/env bats

# ci/scripts/registry-seed.sh — host-seeds the local zot with the digest-
# pinned base images a Dockerfile references, so an in-cluster BuildKit build
# never reaches docker.io / gcr.io (TODOS.md T7b1-followup, the OrbStack
# IPv6-egress defect). A fake `crane` on PATH captures the copy args, so
# these cases cover argument handling + the ref -> zot-path mapping without
# a network. The real copy is proven by `mise run frontend:seed` (recorded
# in TODOS.md T7b1-followup).

setup() {
	load helper
	SW="$CI_SCRIPTS/registry-seed.sh"

	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$FAKEBIN"
	cat >"$FAKEBIN/crane" <<-'SH'
		#!/usr/bin/env bash
		echo "crane $*"
		exit "${STUB_CRANE_RC:-0}"
	SH
	chmod +x "$FAKEBIN/crane"
	PATH="$FAKEBIN:$PATH"

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
	# the source ref carries its digest into `crane copy`
	[[ "$output" == *"@sha256:c0753125"* ]]
}

@test "defaults the registry to localhost:30500" {
	run "$SW" "$DF"
	[ "$status" -eq 0 ]
	[[ "$output" == *"localhost:30500/library/node"* ]]
}

@test "a failed copy -> exit 4, other copies still attempted" {
	STUB_CRANE_RC=1 run "$SW" "$DF"
	[ "$status" -eq 4 ]
	[[ "$output" == *"copy failed"* ]]
	# all three refs were attempted despite the first failing
	[ "$(grep -c 'crane copy' <<<"$output")" -eq 3 ]
}
