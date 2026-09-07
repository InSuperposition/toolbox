# shellcheck shell=bash
#
# environments/local/scripts/lib/openbao.sh — shared helpers for the
# local-OpenBao orchestration scripts (openbao-bootstrap.sh /
# openbao-reset.sh / openbao-snapshot.sh). Self-contained, no repo-level
# runtime lib (F3). Source it; do not execute it.

# write_secret_file <dst> <value> — write <value> into <dst> as a 0600 file,
# atomically. `umask`/`chmod` after the fact is not enough: redirecting into
# an existing 0644 file keeps 0644 and follows symlinks. mktemp+chmod+mv in
# the same directory is atomic and safe.
write_secret_file() {
	local dst="$1" tmp
	tmp="$(mktemp "$(dirname "$dst")/.tmp.XXXXXX")"
	chmod 600 "$tmp"
	printf '%s' "$2" >"$tmp"
	mv -f "$tmp" "$dst"
}

# openbao_wait_ready <listen> — poll the health endpoint until the daemon
# answers (sealedcode/uninitcode/standbycode 200 cover the window between
# process start and static-seal auto-unseal). Non-zero after ~10s.
openbao_wait_ready() {
	local listen="$1" url
	url="http://${listen}/v1/sys/health?sealedcode=200&uninitcode=200&standbycode=200"
	for _ in $(seq 1 50); do
		curl -sf -o /dev/null "$url" && return 0
		sleep 0.2
	done
	echo "OpenBao did not become reachable at $listen" >&2
	return 1
}
