#!/usr/bin/env bash
set -euo pipefail

# `mise run consume -- <registry/repo@sha256:...> <sha256:attestation-digest>`
#
# The consume-side deploy gate for the local cv_frontend demo
# (docs/adr/0009-demo-consumer-is-local-container-not-k8s.md): verify a pinned
# approval attestation, and only if it holds, make that image the one the
# pitchfork `frontend` daemon runs — atomically record it, restart the
# daemon, and report the REAL readiness result (never an assumed success).
#
# A failed verification changes nothing: the state file and the running
# container are left exactly as they were.
#
# Concurrent invocations are a named, accepted constraint (single operator
# — don't run it twice at once). No locking.
#
# Exit 0  — verified, recorded, restarted, and serving on :44100.
# Exit 1  — verification failed (deployment unchanged) OR the daemon did not
#           come ready (recorded + restarted, but not serving — e.g.
#           cv_frontend's own runtime crash; T5b proves the mechanism, not
#           the app).
# Exit 2  — bad arguments.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE="$FRONTEND_DIR/current-image.txt"
PORT=44100                                          # container port — the image's own contract
HOST_PORT="${TOOLBOX_FRONTEND_HOST_PORT:-$PORT}"    # host side; a test overrides it for parallel-safety (CX #7)
DAEMON="frontend"
READY_TIMEOUT="${TOOLBOX_CONSUME_READY_TIMEOUT:-30}"

if [ $# -ne 2 ]; then
	echo "usage: mise run consume -- <registry/repo@sha256:<image>> <sha256:<attestation-digest>>" >&2
	exit 2
fi
IMAGE_REF="$1"
ATT_DIGEST="$2"

# --- 1. Verify. Nothing is touched unless this passes. ---
"$SCRIPT_DIR/verify-approval.sh" "$IMAGE_REF" "$ATT_DIGEST" || {
	echo "consume: verification failed — deployment unchanged" >&2
	exit 1
}

# --- 2. Record atomically (temp + rename). Full reference on line 1 so a
#        later registry migration can't silently reinterpret it. ---
tmp="$(mktemp "${STATE}.XXXXXX")"
printf '%s\n%s\n' "$IMAGE_REF" "$ATT_DIGEST" >"$tmp"
mv -f "$tmp" "$STATE"
echo "consume: recorded $IMAGE_REF"

# --- 3. Restart the daemon onto the new image. ---
pitchfork restart "$DAEMON"

# --- 4. Truthful readiness check on the published host port. ---
deadline=$(( $(date +%s) + READY_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
	code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null || true)"
	if [ -n "$code" ] && [ "$code" != "000" ]; then
		echo "consume: frontend serving on :${HOST_PORT} (HTTP ${code})"
		exit 0
	fi
	sleep 1
done

echo "consume: frontend did NOT come ready on :${HOST_PORT} within ${READY_TIMEOUT}s" >&2
echo "  the image is recorded and the daemon was restarted — check: pitchfork logs ${DAEMON}" >&2
echo "  (cv_frontend has a known Remix v3 runtime crash — T5b proves the pipeline, not the app)" >&2
exit 1
