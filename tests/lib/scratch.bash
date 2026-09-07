# tests/lib/scratch.bash — concern-agnostic scratch-dir helpers.
#
# This file knows nothing about any concern's layout. The caller names the
# repo-relative paths to copy (CX #3 — docs/designs/repo-structure.md
# § The concerns and their allowed edges, FORBIDDEN: `tests/lib ─╳▶ any
# concern`). Loaded through each <tests>/helper.bash.

# toolbox_repo_root — the checkout root, found by walking up from the test
# directory for mise.toml. Depth-independent, so it survives the phased
# tests/ directory moves (Phase 2, Phase 4).
toolbox_repo_root() {
	local d="${BATS_TEST_DIRNAME:?scratch.bash needs BATS_TEST_DIRNAME}"
	while [ "$d" != "/" ] && [ ! -e "$d/mise.toml" ]; do
		d="$(dirname "$d")"
	done
	[ -e "$d/mise.toml" ] || {
		echo "toolbox_repo_root: no mise.toml above $BATS_TEST_DIRNAME" >&2
		return 1
	}
	printf '%s\n' "$d"
}

# scratch_copy <dest> <repo-relative-path>... — copy each path out of the
# checkout into <dest>, keeping its relative location. The caller prunes
# whatever it does not want afterwards (a nested tests/ dir, .terraform, …).
scratch_copy() {
	local dest="$1" repo path
	shift
	repo="$(toolbox_repo_root)" || return 1
	for path in "$@"; do
		mkdir -p "$dest/$(dirname "$path")"
		cp -R "$repo/$path" "$dest/$path"
	done
}
