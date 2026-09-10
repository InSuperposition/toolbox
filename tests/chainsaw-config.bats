#!/usr/bin/env bats

# The repo-root .chainsaw.yaml (investigated 2026-09-10): every `chainsaw
# test` run auto-loads it and every wrapper passes it via --config. It sets
# `namespace.fastDelete: true` so a loaded single-node OrbStack cluster's
# slow ephemeral-namespace teardown does not fail `mise run check` on a
# non-signal. These assert the config is present, well-formed, and wired
# into every chainsaw wrapper.

setup() {
	ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	CFG="$ROOT/.chainsaw.yaml"
}

@test ".chainsaw.yaml exists at the repo root" {
	[ -f "$CFG" ]
}

@test ".chainsaw.yaml is a chainsaw v1alpha2 Configuration" {
	grep -qxF 'apiVersion: chainsaw.kyverno.io/v1alpha2' "$CFG"
	grep -qxF 'kind: Configuration' "$CFG"
}

@test ".chainsaw.yaml sets namespace.fastDelete: true (the flake fix)" {
	# the load-bearing line — without it the cleanup timeout flake returns
	run grep -A2 '^  namespace:' "$CFG"
	[ "$status" -eq 0 ]
	[[ "$output" == *"fastDelete: true"* ]]
}

@test "chainsaw lint accepts it (offline, no cluster)" {
	command -v chainsaw >/dev/null || skip "chainsaw not on PATH"
	# `chainsaw lint` validates the Configuration schema without a cluster
	# (`chainsaw test --config` needs one). Fails non-zero on a malformed
	# config; "The document is valid" + exit 0 on a good one.
	run chainsaw lint configuration -f "$CFG"
	[ "$status" -eq 0 ]
	[[ "$output" == *"valid"* ]]
}

@test "every chainsaw wrapper passes --config <repo-root>/.chainsaw.yaml" {
	local w missing=""
	for w in \
		"$ROOT/environments/local/scripts/flux-chainsaw.sh" \
		"$ROOT/environments/local/scripts/openbao-chainsaw.sh" \
		"$ROOT/environments/local/scripts/kyverno-chainsaw.sh" \
		"$ROOT/environments/local/scripts/frontend-chainsaw.sh" \
		"$ROOT/ci/scripts/chainsaw-test.sh"; do
		grep -q -- '--config ' "$w" && grep -q '\.chainsaw\.yaml' "$w" || missing="$missing $w"
	done
	[ -z "$missing" ] || { echo "wrappers not passing --config:$missing"; false; }
}
