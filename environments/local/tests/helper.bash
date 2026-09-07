# environments/local test helpers. For now just the shared per-run
# isolation lib (free_port) — the scratch-copy idiom in these suites is
# adopted from tests/lib/scratch.bash in Phase 2, when `git mv` moves this
# directory to environments/local/scripts/tests/.

_d="$BATS_TEST_DIRNAME"
while [ "$_d" != "/" ] && [ ! -e "$_d/mise.toml" ]; do _d="$(dirname "$_d")"; done
# shellcheck source=/dev/null
. "$_d/tests/lib/ports.bash"
unset _d
