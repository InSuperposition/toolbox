# tests/lib/ports.bash — per-run network isolation so suites can run in
# parallel (e.g. two `mise run check` in separate worktrees). Loaded first
# by each <tests>/helper.bash that needs it — registry.bash relies on
# free_port being defined.

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
