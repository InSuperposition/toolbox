#!/usr/bin/env bats

# environments/local/scripts/spire-verify.sh — the chart-pin gate for the
# classic (non-OCI) spiffe/helm-charts-hardened repo.
#
# The digest-pin error paths run against a local, throwaway classic Helm
# repo (tests/lib/helm_repo.bash) instead of live spiffe.github.io — no
# network, no flakiness, same shape as openbao-verify.bats's
# push_local_fixture. The fixture charts are trivial placeholders (one
# ConfigMap template), not real spire/spire-crds content — same split as
# openbao-verify.bats's: a local fixture covers the digest-pin path
# (helm pull + shasum + lock comparison), not the `helm template`
# render-shape assertions, which stay covered by the live happy-path test
# only. Lock-integrity cases (missing field, bad digest format, missing
# file) need no network at all.

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
	[ -n "${HELM_REPO:-}" ] && stop_helm_repo "$SCRATCH"
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

# push_local_fixture — stage spire-crds + spire as trivial fixture charts,
# serve them over a local classic Helm repo, and write a fully-correct
# spire.lock pointing at them (both digests real and matching, computed
# the same way spire-verify.sh itself computes them: shasum the pulled
# .tgz). Sets CRDS_DIGEST / SPIRE_DIGEST so a test can mutate exactly one
# field afterward.
push_local_fixture() {
	helm_repo_pack "$SCRATCH" spire-crds 0.6.1
	helm_repo_pack "$SCRATCH" spire 0.30.2
	start_helm_repo "$SCRATCH"

	CRDS_DIGEST="sha256:$(shasum -a 256 "$SCRATCH/repo/spire-crds-0.6.1.tgz" | cut -d' ' -f1)"
	SPIRE_DIGEST="sha256:$(shasum -a 256 "$SCRATCH/repo/spire-0.30.2.tgz" | cut -d' ' -f1)"

	write_lock "$HELM_REPO" "0.6.1" "$CRDS_DIGEST" "0.30.2" "$SPIRE_DIGEST"
}

@test "passes against the real repo (or cleanly skips offline)" {
	if ! online; then
		skip "no network to spiffe.github.io"
	fi
	run "$SW"
	[ "$status" -eq 0 ]
	[[ "$output" == *"spire-verify: OK"* ]]
}

@test "fails closed on a mutated spire-crds chart digest (local fixture, no live network)" {
	push_local_fixture
	sed -i.bak 's/^spire_crds_chart_digest=.*/spire_crds_chart_digest=sha256:0000000000000000000000000000000000000000000000000000000000000000/' "$LOCK"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"lock says"* ]]
}

@test "fails closed on a mutated spire chart digest (local fixture, no live network)" {
	push_local_fixture
	sed -i.bak 's/^spire_chart_digest=.*/spire_chart_digest=sha256:1111111111111111111111111111111111111111111111111111111111111111/' "$LOCK"
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
