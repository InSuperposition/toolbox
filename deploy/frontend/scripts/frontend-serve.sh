#!/usr/bin/env bash
set -euo pipefail

# pitchfork daemon entrypoint for the local cv_frontend demo deploy
# (docs/adr/0009-demo-consumer-is-local-container-not-k8s.md). pitchfork runs
# this with cwd = deploy/frontend (pitchfork.toml `dir`); it is also safe to
# run directly. pitchfork.toml points `run` at this script and nothing else
# — a deploy records the approved image in current-image.txt, it never
# rewrites pitchfork's own config.
#
# Reads the currently-approved image from current-image.txt (written
# atomically by `mise run frontend:deploy`), RE-VERIFIES its approval at
# launch time (not just at deploy time), then runs `docker run` in the
# foreground so pitchfork is the sole supervisor.
#
# The verify seam lives in the attestation/ concern; this reaches it through
# lib/frontend.sh's TOOLBOX_ATTESTATION_VERIFY seam (the one allowed
# cross-concern edge — repo-structure.md § The concerns, ADR 0013).
#
# Launch re-verify (Codex P1-8): bounded retries + backoff on a retryable
# verify failure (registry unreachable / referrer not propagated), then a
# clear stopped state — never an unbounded loop. A TERMINAL verify failure
# (bad signature / verdict rejected / wrong subject) stops immediately, no
# retries. Must work on a COLD, non-interactive start with no inherited
# shell credentials — the image and its referrers are pulled anonymously.
#
# Known gap, named not solved: this only gates the LAUNCH. It does not stop
# an already-running container whose image is rejected afterwards — that
# needs a separate watch, deferred.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null  # lib is exercised via frontend-serve.bats
. "$SCRIPT_DIR/lib/frontend.sh"
cd "$SCRIPT_DIR/.."

STATE="current-image.txt"
PORT=44100                                            # container port — the image's own contract
HOST_PORT="${TOOLBOX_FRONTEND_HOST_PORT:-$PORT}"      # host side; a test overrides it for parallel-safety (CX #7)
NAME="${TOOLBOX_FRONTEND_CONTAINER:-toolbox-frontend}"
MAX_ATTEMPTS="${TOOLBOX_FRONTEND_VERIFY_ATTEMPTS:-5}"

stopped() { echo "frontend: $1 — not launching" >&2; exit 1; }

[ -f "$STATE" ] || stopped "no approved image yet (run: mise run frontend:deploy -- <registry/repo@sha256:...> <sha256:attestation>)"

# Two lines: full image reference, then the approval-attestation digest.
image_ref="$(sed -n '1p' "$STATE")"
att_digest="$(sed -n '2p' "$STATE")"
[ -n "$image_ref" ] && [ -n "$att_digest" ] || stopped "$STATE is malformed (need: <image-ref> on line 1, <attestation-digest> on line 2)"

# Cold-start hygiene: pull anonymously, no inherited docker/gh credentials.
SCRATCH_DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG="$SCRATCH_DOCKER_CONFIG"
unset GH_TOKEN GITHUB_TOKEN VAULT_TOKEN 2>/dev/null || true

NAME_SET=""
# shellcheck disable=SC2329  # invoked via the EXIT / TERM / INT traps below
cleanup() {
	[ -n "$NAME_SET" ] && { docker stop -t 5 "$NAME" >/dev/null 2>&1 || true; docker rm -f "$NAME" >/dev/null 2>&1 || true; }
	rm -rf "$SCRATCH_DOCKER_CONFIG"
}
trap cleanup EXIT
trap 'cleanup; exit 143' TERM INT

attempt=1
while :; do
	set +e
	frontend_attestation_verify "$image_ref" "$att_digest"
	rc=$?
	set -e
	case "$rc" in
	0)
		break
		;;
	3)
		if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
			stopped "could not verify $image_ref after $MAX_ATTEMPTS attempts (registry unreachable?)"
		fi
		backoff=$((2 ** attempt))
		echo "frontend: verify attempt $attempt/$MAX_ATTEMPTS not ready (retryable) — retrying in ${backoff}s" >&2
		sleep "$backoff"
		attempt=$((attempt + 1))
		;;
	*)
		stopped "$image_ref failed approval verification (exit $rc) — see the line above"
		;;
	esac
done

echo "frontend: $image_ref verified approved — starting on :$HOST_PORT" >&2

# Run the container as a tracked child, NOT `exec docker run`: pitchfork's
# stop can SIGKILL the `docker run` CLI without it forwarding to the
# daemon-owned container, orphaning it. Staying PID 1 lets the traps above
# `docker stop` it explicitly so nothing is left behind.
docker rm -f "$NAME" >/dev/null 2>&1 || true
NAME_SET=1

docker run --rm --name "$NAME" --platform linux/arm64 -p "${HOST_PORT}:${PORT}" "$image_ref" &
child=$!
set +e
wait "$child"
rc=$?
set -e
echo "frontend: container exited (code $rc)" >&2
exit "$rc"
