# tests/lib/ports.bash — per-run network isolation so suites can run in
# parallel (e.g. two `mise run check` in separate worktrees). Loaded first
# by each <tests>/helper.bash — registry.bash and the frontend helper both
# rely on free_port being defined.

# free_port — an unused loopback TCP port.
free_port() {
	python3 - <<-'PY'
		import socket
		s = socket.socket()
		s.bind(("127.0.0.1", 0))
		print(s.getsockname()[1])
		s.close()
	PY
}

# frontend_isolation — call in a bats setup(). Exports the two seams that
# frontend-serve.sh / frontend-deploy.sh / scratch_frontend read so a docker
# deploy test never collides with another run's container or host port. The
# container port
# stays fixed (44100 — the image's own contract, CX #7); only the host side
# is mapped to a free port.
#   TOOLBOX_FRONTEND_HOST_PORT  — free host port
#   TOOLBOX_FRONTEND_CONTAINER  — unique container name for this run + test
frontend_isolation() {
	export TOOLBOX_FRONTEND_HOST_PORT
	TOOLBOX_FRONTEND_HOST_PORT="$(free_port)"
	export TOOLBOX_FRONTEND_CONTAINER="toolbox-frontend-test-$$-${BATS_TEST_NUMBER:-0}"
}
