#!/usr/bin/env bats

# frontend-serve.sh — the pitchfork `frontend` daemon entrypoint. Re-reads
# current-image.txt, re-verifies the approval at launch through the DEFAULT
# TOOLBOX_ATTESTATION_VERIFY seam (no test overrides it — scratch_frontend
# copies attestation/ + a mise.toml marker, so lib/frontend.sh resolves the
# seam inside the scratch, C4), then runs the container in the foreground.
#
# Covers docs/adr/0009-demo-consumer-is-local-container-not-k8s.md. The
# no-docker cases run always; the container case skips without docker.
# pitchfork commands run against a SCRATCH pitchfork.toml so a real
# `frontend` daemon is never touched.

setup() {
	load helper
	FIX="$(mktemp -d)"
	# per-run host port + container name so a docker run never collides with
	# (or tears down) another run's container.
	frontend_isolation
}

teardown() {
	load helper
	if [ -n "${SCRATCH:-}" ] && [ -f "$SCRATCH/pitchfork.toml" ]; then
		(
			cd "$SCRATCH" &&
				pitchfork stop frontend >/dev/null 2>&1
			pitchfork daemons remove frontend >/dev/null 2>&1
		) || true
	fi
	docker rm -f "${TOOLBOX_FRONTEND_CONTAINER:-toolbox-frontend}" >/dev/null 2>&1 || true
	if [ -n "${FIX:-}" ]; then
		stop_docker_registry "$FIX"
		stop_registry "$FIX"
	fi
	rm -rf "$FIX" "${SCRATCH:-}"
}

# new_scratch — sets SCRATCH (checkout slice root) and SD (its deploy/frontend).
# NOT a command substitution: the assignments must land in the test shell.
new_scratch() {
	SCRATCH="$(mktemp -d)"
	scratch_frontend "$SCRATCH"
	SD="$SCRATCH/deploy/frontend"
}

@test "frontend-serve: no current-image.txt -> stopped, exit 1" {
	new_scratch
	run "$SD/scripts/frontend-serve.sh"
	[ "$status" -eq 1 ]
	[[ "$output" == *"no approved image yet"* ]]
}

@test "frontend-serve: malformed current-image.txt -> stopped, exit 1" {
	new_scratch
	printf 'only-one-line\n' >"$SD/current-image.txt"
	run "$SD/scripts/frontend-serve.sh"
	[ "$status" -eq 1 ]
	[[ "$output" == *"malformed"* ]]
}

@test "frontend-serve: registry unreachable -> default seam returns retryable, bounded retry then stopped" {
	# The designated default-seam case (C4): no TOOLBOX_ATTESTATION_VERIFY —
	# lib/frontend.sh resolves the seam to the scratch attestation/ copy,
	# whose attestation-verify.sh returns exit 3 (retryable) for an
	# unreachable registry.
	new_scratch
	z="$(printf '0%.0s' {1..64})"
	printf '127.0.0.1:59999/none@sha256:%s\nsha256:%s\n' "$z" "$z" >"$SD/current-image.txt"
	start=$SECONDS
	TOOLBOX_FRONTEND_VERIFY_ATTEMPTS=3 run "$SD/scripts/frontend-serve.sh"
	elapsed=$((SECONDS - start))
	[ "$status" -eq 1 ]
	[[ "$output" == *"after 3 attempts"* ]]
	[ "$elapsed" -lt 20 ]   # 2s + 4s backoff, bounded — not an unbounded loop
}

@test "frontend-serve: a terminal verification failure does not retry" {
	load helper
	start_registry "$FIX"; make_key "$FIX"
	img="$(make_image "$FIX")"
	att="$(sign_image "$img" approve)"
	new_scratch
	printf '%s\n%s\n' "$img" "$att" >"$SD/current-image.txt"
	( cd "$FIX" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix wrong >/dev/null 2>&1 )
	start=$SECONDS
	TOOLBOX_APPROVAL_PUBKEY="$FIX/wrong.pub" TOOLBOX_FRONTEND_VERIFY_ATTEMPTS=5 run "$SD/scripts/frontend-serve.sh"
	elapsed=$((SECONDS - start))
	[ "$status" -eq 1 ]
	[[ "$output" == *"failed approval verification"* ]]
	[ "$elapsed" -lt 3 ]   # no backoff sleeps — terminal, gave up at once
	stop_registry "$FIX"
}

@test "frontend-serve: default seam verifies an approved image, then proceeds to launch (C4)" {
	load helper
	start_registry "$FIX"; make_key "$FIX"
	img="$(make_image "$FIX")"
	att="$(sign_image "$img" approve "clean")"
	new_scratch
	cp "$FIX/cosign.pub" "$SCRATCH/attestation/cosign-approval.pub"
	printf '%s\n%s\n' "$img" "$att" >"$SD/current-image.txt"
	# no TOOLBOX_ATTESTATION_VERIFY, no TOOLBOX_APPROVAL_PUBKEY — the default
	# seam resolves to the scratch attestation/ copy and its committed pub.
	TOOLBOX_FRONTEND_VERIFY_ATTEMPTS=1 run "$SD/scripts/frontend-serve.sh"
	[[ "$output" == *"verified approved"* ]]        # got past the default seam
	[[ "$output" != *"retrying in"* ]]              # verified first try, no retry loop
	stop_registry "$FIX"
}

@test "[docker] pitchfork stop -> container gone, no orphan; restart -> exactly one" {
	load helper
	deploy_docker_available || skip "docker not available"
	start_docker_registry "$FIX"
	start_registry "$FIX"; make_key "$FIX"
	img="$(make_serving_image "$FIX")"
	att="$(sign_image "$img" approve)"
	SCRATCH="$(mktemp -d)"; scratch_frontend "$SCRATCH"
	cp "$FIX/cosign.pub" "$SCRATCH/attestation/cosign-approval.pub"
	printf '%s\n%s\n' "$img" "$att" >"$SCRATCH/deploy/frontend/current-image.txt"

	( cd "$SCRATCH" && pitchfork start frontend >/dev/null 2>&1 )
	sleep 3
	[ "$(docker ps --filter "name=${TOOLBOX_FRONTEND_CONTAINER}" -q | wc -l | tr -d ' ')" -eq 1 ]

	( cd "$SCRATCH" && pitchfork stop frontend >/dev/null 2>&1 )
	sleep 2
	[ "$(docker ps -a --filter "name=${TOOLBOX_FRONTEND_CONTAINER}" -q | wc -l | tr -d ' ')" -eq 0 ]

	( cd "$SCRATCH" && pitchfork start frontend >/dev/null 2>&1 )
	sleep 3
	( cd "$SCRATCH" && pitchfork start frontend >/dev/null 2>&1 || true )
	sleep 1
	[ "$(docker ps --filter "name=${TOOLBOX_FRONTEND_CONTAINER}" -q | wc -l | tr -d ' ')" -eq 1 ]
}
