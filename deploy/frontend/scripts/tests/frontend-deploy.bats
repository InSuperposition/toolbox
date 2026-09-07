#!/usr/bin/env bats

# frontend-deploy.sh — `mise run frontend:deploy`. Verifies a pinned
# approval attestation through the DEFAULT TOOLBOX_ATTESTATION_VERIFY seam
# (scratch_frontend copies attestation/ + a mise.toml marker, C4), and only
# if it holds records current-image.txt + restarts the daemon + reports the
# real readiness result.
#
# Covers docs/adr/0009-demo-consumer-is-local-container-not-k8s.md. The
# no-docker cases run always; the container cases skip without docker.

setup() {
	load helper
	FIX="$(mktemp -d)"
	SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
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

@test "frontend-deploy: bad arguments -> exit 2" {
	run "$SCRIPTS/frontend-deploy.sh" only-one-arg
	[ "$status" -eq 2 ]
}

@test "frontend-deploy: verification failure leaves the state file untouched" {
	new_scratch
	a="$(printf 'a%.0s' {1..64})"
	printf '127.0.0.1:59998/x/y@sha256:%s\nsha256:%s\n' "$a" "$a" >"$SD/current-image.txt"
	before="$(cat "$SD/current-image.txt")"
	# an unreachable local registry — verify fails (retryable), so deploy
	# touches nothing.
	run bash -c "cd '$SCRATCH' && ./deploy/frontend/scripts/frontend-deploy.sh \
		'127.0.0.1:59998/x/y@sha256:$(printf 'c%.0s' {1..64})' \
		'sha256:$(printf 'd%.0s' {1..64})'"
	[ "$status" -eq 1 ]
	[[ "$output" == *"deployment unchanged"* ]]
	[ "$(cat "$SD/current-image.txt")" = "$before" ]
}

@test "[docker] frontend-deploy an approved image -> serves on the published port, records both lines" {
	load helper
	deploy_docker_available || skip "docker not available"
	start_docker_registry "$FIX"
	start_registry "$FIX"; make_key "$FIX"
	img="$(make_serving_image "$FIX")"
	att="$(sign_image "$img" approve)"

	SCRATCH="$(mktemp -d)"; scratch_frontend "$SCRATCH"
	cp "$FIX/cosign.pub" "$SCRATCH/attestation/cosign-approval.pub"

	run bash -c "cd '$SCRATCH' && ./deploy/frontend/scripts/frontend-deploy.sh '$img' '$att'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"serving on :${TOOLBOX_FRONTEND_HOST_PORT}"* ]]
	[ "$(sed -n '1p' "$SCRATCH/deploy/frontend/current-image.txt")" = "$img" ]
	[ "$(sed -n '2p' "$SCRATCH/deploy/frontend/current-image.txt")" = "$att" ]
	run curl -s "http://127.0.0.1:${TOOLBOX_FRONTEND_HOST_PORT}/"
	[[ "$output" == *"t5b ok"* ]]
}

@test "[docker] a rejected attestation after a good deploy leaves the running container alone" {
	load helper
	deploy_docker_available || skip "docker not available"
	start_docker_registry "$FIX"
	start_registry "$FIX"; make_key "$FIX"
	img="$(make_serving_image "$FIX")"
	good="$(sign_image "$img" approve)"
	bad="$(sign_image "$img" reject)"
	SCRATCH="$(mktemp -d)"; scratch_frontend "$SCRATCH"
	cp "$FIX/cosign.pub" "$SCRATCH/attestation/cosign-approval.pub"

	bash -c "cd '$SCRATCH' && ./deploy/frontend/scripts/frontend-deploy.sh '$img' '$good'"
	before="$(cat "$SCRATCH/deploy/frontend/current-image.txt")"
	cid_before="$(docker ps --filter "name=${TOOLBOX_FRONTEND_CONTAINER}" -q)"

	run bash -c "cd '$SCRATCH' && ./deploy/frontend/scripts/frontend-deploy.sh '$img' '$bad'"
	[ "$status" -eq 1 ]
	[[ "$output" == *"verdict: rejected"* ]] || [[ "$output" == *"deployment unchanged"* ]]
	[ "$(cat "$SCRATCH/deploy/frontend/current-image.txt")" = "$before" ]
	[ "$(docker ps --filter "name=${TOOLBOX_FRONTEND_CONTAINER}" -q)" = "$cid_before" ]
}
