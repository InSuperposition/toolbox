#!/usr/bin/env bats

# The local pitchfork-supervised demo deploy. run.sh (pitchfork daemon
# entrypoint) + consume.sh (`mise run consume`).
#
# Covers docs/adr/0009-demo-consumer-is-local-container-not-k8s.md. The
# no-docker cases run always; the container cases skip when docker is
# unavailable. pitchfork commands run against a SCRATCH pitchfork.toml so a
# real `frontend` daemon is never touched.

setup() {
	load helper
	FIX="$(mktemp -d)"
	SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	FRONTEND="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
	# per-run host port + container name so a docker deploy test never
	# collides with (or tears down) another run's container.
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

# state file lives next to run.sh — a scratch copy per test keeps the real
# one untouched.
state_dir() {
	SCRATCH="$(mktemp -d)"
	scratch_frontend "$SCRATCH"
	echo "$SCRATCH/deploy/frontend"
}

@test "run.sh: no current-image.txt -> stopped, exit 1" {
	sd="$(state_dir)"
	run "$sd/run.sh"
	[ "$status" -eq 1 ]
	[[ "$output" == *"no approved image yet"* ]]
}

@test "run.sh: malformed current-image.txt -> stopped, exit 1" {
	sd="$(state_dir)"
	printf 'only-one-line\n' >"$sd/current-image.txt"
	run "$sd/run.sh"
	[ "$status" -eq 1 ]
	[[ "$output" == *"malformed"* ]]
}

@test "run.sh: registry unreachable -> bounded retry then stopped, never a hang" {
	sd="$(state_dir)"
	z="$(printf '0%.0s' {1..64})"
	printf '127.0.0.1:59999/none@sha256:%s\nsha256:%s\n' "$z" "$z" >"$sd/current-image.txt"
	start=$SECONDS
	TOOLBOX_FRONTEND_VERIFY_ATTEMPTS=3 run "$sd/run.sh"
	elapsed=$((SECONDS - start))
	[ "$status" -eq 1 ]
	[[ "$output" == *"after 3 attempts"* ]]
	[ "$elapsed" -lt 20 ]   # 2s + 4s backoff, bounded — not an unbounded loop
}

@test "run.sh: a terminal verification failure does not retry" {
	load helper
	start_registry "$FIX"; make_key "$FIX"
	img="$(make_image "$FIX")"
	att="$(sign_local "$img" approve)"
	sd="$(state_dir)"
	printf '%s\n%s\n' "$img" "$att" >"$sd/current-image.txt"
	( cd "$FIX" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix wrong >/dev/null 2>&1 )
	start=$SECONDS
	TOOLBOX_APPROVAL_PUBKEY="$FIX/wrong.pub" TOOLBOX_FRONTEND_VERIFY_ATTEMPTS=5 run "$sd/run.sh"
	elapsed=$((SECONDS - start))
	[ "$status" -eq 1 ]
	[[ "$output" == *"failed approval verification"* ]]
	[ "$elapsed" -lt 3 ]   # no backoff sleeps — terminal, gave up at once
	stop_registry "$FIX"
}

@test "consume.sh: bad arguments -> exit 2" {
	run "$SCRIPTS/consume.sh" only-one-arg
	[ "$status" -eq 2 ]
}

@test "consume.sh: verification failure leaves the state file untouched" {
	sd="$(state_dir)"
	printf 'ghcr.io/x/y@sha256:%s\nsha256:%s\n' "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})" >"$sd/current-image.txt"
	before="$(cat "$sd/current-image.txt")"
	# point consume at the scratch copy
	run env TOOLBOX_APPROVAL_PUBKEY="$FRONTEND/cosign-approval.pub" \
		"$sd/scripts/consume.sh" \
		"ghcr.io/x/y@sha256:$(printf 'c%.0s' {1..64})" \
		"sha256:$(printf 'd%.0s' {1..64})"
	[ "$status" -eq 1 ]
	[[ "$output" == *"deployment unchanged"* ]]
	[ "$(cat "$sd/current-image.txt")" = "$before" ]
}

@test "[docker] consume an approved image -> serves on the published port, records both lines" {
	load helper
	deploy_docker_available || skip "docker not available"
	start_docker_registry "$FIX"
	start_registry "$FIX"; make_key "$FIX"
	img="$(make_serving_image "$FIX")"
	att="$(sign_local "$img" approve)"

	SCRATCH="$(mktemp -d)"; scratch_frontend "$SCRATCH"
	cp "$FIX/cosign.pub" "$SCRATCH/deploy/frontend/cosign-approval.pub"

	run bash -c "cd '$SCRATCH' && ./deploy/frontend/scripts/consume.sh '$img' '$att'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"serving on :${TOOLBOX_FRONTEND_HOST_PORT}"* ]]
	[ "$(sed -n '1p' "$SCRATCH/deploy/frontend/current-image.txt")" = "$img" ]
	[ "$(sed -n '2p' "$SCRATCH/deploy/frontend/current-image.txt")" = "$att" ]
	run curl -s "http://127.0.0.1:${TOOLBOX_FRONTEND_HOST_PORT}/"
	[[ "$output" == *"t5b ok"* ]]
}

@test "[docker] pitchfork stop -> container gone, no orphan; restart -> exactly one" {
	load helper
	deploy_docker_available || skip "docker not available"
	start_docker_registry "$FIX"
	start_registry "$FIX"; make_key "$FIX"
	img="$(make_serving_image "$FIX")"
	att="$(sign_local "$img" approve)"
	SCRATCH="$(mktemp -d)"; scratch_frontend "$SCRATCH"
	cp "$FIX/cosign.pub" "$SCRATCH/deploy/frontend/cosign-approval.pub"
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

@test "[docker] a rejected attestation after a good deploy leaves the running container alone" {
	load helper
	deploy_docker_available || skip "docker not available"
	start_docker_registry "$FIX"
	start_registry "$FIX"; make_key "$FIX"
	img="$(make_serving_image "$FIX")"
	good="$(sign_local "$img" approve)"
	bad="$(sign_local "$img" reject)"
	SCRATCH="$(mktemp -d)"; scratch_frontend "$SCRATCH"
	cp "$FIX/cosign.pub" "$SCRATCH/deploy/frontend/cosign-approval.pub"

	bash -c "cd '$SCRATCH' && ./deploy/frontend/scripts/consume.sh '$img' '$good'"
	before="$(cat "$SCRATCH/deploy/frontend/current-image.txt")"
	cid_before="$(docker ps --filter "name=${TOOLBOX_FRONTEND_CONTAINER}" -q)"

	run bash -c "cd '$SCRATCH' && ./deploy/frontend/scripts/consume.sh '$img' '$bad'"
	[ "$status" -eq 1 ]
	[[ "$output" == *"verdict: rejected"* ]] || [[ "$output" == *"deployment unchanged"* ]]
	[ "$(cat "$SCRATCH/deploy/frontend/current-image.txt")" = "$before" ]
	[ "$(docker ps --filter "name=${TOOLBOX_FRONTEND_CONTAINER}" -q)" = "$cid_before" ]
}
