#!/usr/bin/env bats

# deploy/frontend/Dockerfile line 1 must pin the BuildKit frontend by
# digest, not just by the mutable `docker/dockerfile:1` tag. Pinning the
# BuildKit image + the base images does NOT pin the build implementation —
# the `# syntax=` directive pulls a frontend image at build time. For a
# repo whose thesis is "the content digest is the trust boundary"
# (ADR 0001) an unpinned `# syntax=` is an input-trust hole (T7a; the
# dockerfile-syntax-directive-is-unpinned-executable-input learning).
#
# Catches a future revert of the pin — `mise run check` goes red.

setup() {
	load helper
	DOCKERFILE="$(toolbox_repo_root)/deploy/frontend/Dockerfile"
}

@test "Dockerfile line 1 pins the syntax frontend by digest" {
	run head -n1 "$DOCKERFILE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^\#\ syntax=docker/dockerfile:1@sha256:[0-9a-f]{64}$ ]]
}

@test "no unpinned '# syntax=' directive anywhere in the Dockerfile" {
	# a bare `# syntax=docker/dockerfile:1` with no @sha256 must not appear
	run grep -nE '^#\s*syntax=[^@]*$' "$DOCKERFILE"
	[ "$status" -ne 0 ]
}
