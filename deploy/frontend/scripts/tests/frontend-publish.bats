#!/usr/bin/env bats

# frontend-publish.sh — `mise run frontend:publish`. Renders the cv_frontend
# Timoni module against an APPROVED image digest and flux-pushes the
# manifests as an OCI artifact (Plan B M3, docs/adr/0019).
#
# These cover argument validation and the verify gate — the operator-boundary
# contract that NOTHING is rendered or pushed unless the pinned approval
# attestation holds. The verify seam is stubbed via TOOLBOX_ATTESTATION_VERIFY.
# The full render + `flux push` is the documented live run (needs the module,
# `timoni`/`flux`, and a reachable zot) — same split as frontend-build.bats.

setup() {
	load helper
	SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	D64="$(printf 'a%.0s' {1..64})"
	IMG="ghcr.io/insuperposition/cv-frontend@sha256:${D64}"
	ATT="sha256:${D64}"

	STUB="$BATS_TEST_TMPDIR/verify-stub.sh"
	cat >"$STUB" <<-'SH'
		#!/usr/bin/env bash
		# exit code driven by STUB_VERIFY_RC (default 0)
		echo "verify-stub called: $*"
		exit "${STUB_VERIFY_RC:-0}"
	SH
	chmod +x "$STUB"
	export TOOLBOX_ATTESTATION_VERIFY="$STUB"
}

@test "frontend-publish: too few arguments -> exit 2" {
	run "$SCRIPTS/frontend-publish.sh" "$IMG" "$ATT"
	[ "$status" -eq 2 ]
	[[ "$output" == *"usage:"* ]]
}

@test "frontend-publish: a tag-only image reference -> exit 2" {
	run "$SCRIPTS/frontend-publish.sh" "ghcr.io/insuperposition/cv-frontend:main" "$ATT" rev1
	[ "$status" -eq 2 ]
	[[ "$output" == *"not a full digest reference"* ]]
}

@test "frontend-publish: a short / non-canonical image digest -> exit 2" {
	run "$SCRIPTS/frontend-publish.sh" "ghcr.io/insuperposition/cv-frontend@sha256:abc123" "$ATT" rev1
	[ "$status" -eq 2 ]
	[[ "$output" == *"canonical sha256"* ]]
}

@test "frontend-publish: a bad attestation digest -> exit 2" {
	run "$SCRIPTS/frontend-publish.sh" "$IMG" "not-a-digest" rev1
	[ "$status" -eq 2 ]
}

@test "frontend-publish: an unusable revision tag -> exit 2" {
	run "$SCRIPTS/frontend-publish.sh" "$IMG" "$ATT" 'bad rev/with spaces'
	[ "$status" -eq 2 ]
}

@test "frontend-publish: verification failure -> exit 1, nothing rendered or pushed" {
	STUB_VERIFY_RC=1 run "$SCRIPTS/frontend-publish.sh" "$IMG" "$ATT" rev1
	[ "$status" -eq 1 ]
	[[ "$output" == *"verification failed"* ]]
	[[ "$output" == *"nothing rendered or pushed"* ]]
	# the verify seam was actually consulted
	[[ "$output" == *"verify-stub called"* ]]
}
