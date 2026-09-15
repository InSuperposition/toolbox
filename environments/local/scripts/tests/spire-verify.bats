#!/usr/bin/env bats

# environments/local/scripts/spire-verify.sh — the chart-pin gate for the
# classic (non-OCI) spiffe/helm-charts-hardened repo.
#
# UNLIKE openbao-verify.bats, this suite has no local-fixture rigor for
# the chart-dependent cases (helm pull / helm template) — this repo has
# no equivalent of tests/lib/registry.bash's throwaway TLS registry for
# a CLASSIC Helm repo (index.yaml + bare .tgz over plain HTTP), only for
# OCI/zot. Building that fixture is a real, separate test-infra gap —
# logged as a new TODOS.md P3 item rather than expanding this PR's
# scope. Lock-integrity cases (missing field, bad digest format, missing
# file) need no network and run offline, same as openbao-verify.bats's.

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" \
		"environments/local/spire" \
		"environments/local/scripts/spire-verify.sh"
	SW="$SCRATCH/environments/local/scripts/spire-verify.sh"
	LOCK="$SCRATCH/environments/local/spire/spire.lock"
}

teardown() {
	cd /
	rm -rf "$SCRATCH"
}

online() {
	helm pull spire --repo https://spiffe.github.io/helm-charts-hardened/ \
		--version 0.30.2 --destination "$(mktemp -d)" >/dev/null 2>&1
}

write_lock() {
	cat >"$LOCK" <<EOF
chart_repository=$1
spire_crds_chart_version=$2
spire_crds_chart_digest=$3
spire_chart_version=$4
spire_chart_digest=$5
app_version=1.15.3
EOF
}

@test "passes against the real repo (or cleanly skips offline)" {
	if ! online; then
		skip "no network to spiffe.github.io"
	fi
	run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"spire-verify: OK"* ]]
}

@test "fails closed on a mutated spire chart digest" {
	if ! online; then
		skip "no network to spiffe.github.io"
	fi
	write_lock \
		"https://spiffe.github.io/helm-charts-hardened/" \
		"0.6.1" "sha256:ce982e63fc375e392b014fc99e621a55442ab886052413e9bb052f72d66580a8" \
		"0.30.2" "sha256:0000000000000000000000000000000000000000000000000000000000000"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"lock says"* ]]
}

@test "fails when the lock is missing a field" {
	: >"$LOCK"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing a field"* ]]
}

@test "fails when spire_chart_digest is not sha256:<hex>" {
	write_lock \
		"https://spiffe.github.io/helm-charts-hardened/" \
		"0.6.1" "sha256:ce982e63fc375e392b014fc99e621a55442ab886052413e9bb052f72d66580a8" \
		"0.30.2" "not-a-digest"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"is not sha256:<hex>"* ]]
}

@test "fails when the lock file is absent" {
	rm -f "$LOCK"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"lock file not found"* ]]
}

@test "shellcheck-clean" {
	run shellcheck "$SW"
	[ "$status" -eq 0 ]
}
