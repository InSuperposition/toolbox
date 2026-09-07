# tests/lib/assert.bash — portable structured assertions for bats suites.
#
# The restructure deferred this file until a suite first needed a
# structured assertion (docs/designs/repo-structure.md § The concerns).
# openbao-bootstrap.bats checking file modes on both macOS (dev) and Linux
# (CI, T9a) is that moment: `stat` takes different flags on BSD and GNU.

# file_mode <path> — echo the octal permission bits of <path> (e.g. 600).
# GNU coreutils first (`-c %a`), BSD/macOS fallback (`-f %A`).
file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%A' "$1"
}
