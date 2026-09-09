#!/usr/bin/env bats

# environments/local/scripts/openbao-cluster-verify.sh — the Increment 4a
# chart-pin gate. The guard must FAIL closed on a mutated digest / broken
# lock, not only pass on the committed one.
#
# The digest-equality + render assertions need network (crane + `helm pull`).
# On a green network they run for real; offline / registry-down the script
# prints a skip line and exits 0 (like the [k8s] gates) so a flapping
# registry does not red `mise run check`. The lock-integrity cases
# (missing field, bad digest format, missing file) need no network and
# always assert.

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" \
		"environments/local/openbao-cluster" \
		"environments/local/scripts/openbao-cluster-verify.sh"
	: >"$SCRATCH/mise.toml"
	SW="$SCRATCH/environments/local/scripts/openbao-cluster-verify.sh"
	LOCK="$SCRATCH/environments/local/openbao-cluster/openbao-cluster.lock"
}

teardown() {
	cd /
	rm -rf "$SCRATCH"
}

online() {
	crane digest ghcr.io/openbao/charts/openbao:0.29.4 >/dev/null 2>&1
}

@test "passes on the committed lock (or cleanly skips offline)" {
	run "$SW"
	[ "$status" -eq 0 ]
	if online; then
		[[ "$output" == *"OK — chart"* ]]
	else
		[[ "$output" == *"skipping"* ]]
	fi
}

@test "fails closed on a mutated chart digest" {
	online || skip "offline — the digest-equality gate needs the registry"
	sed -i.bak 's/^chart_digest=sha256:.*/chart_digest=sha256:0000000000000000000000000000000000000000000000000000000000000000/' "$LOCK"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"resolves to"* ]]
}

@test "fails closed on a mutated image digest" {
	online || skip "offline — the digest-equality gate needs the registry"
	sed -i.bak 's/^image_digest=sha256:.*/image_digest=sha256:1111111111111111111111111111111111111111111111111111111111111111/' "$LOCK"
	run "$SW"
	[ "$status" -ne 0 ]
}

@test "fails when the lock is missing a field" {
	sed -i.bak '/^chart_version=/d' "$LOCK"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing a field"* ]]
}

@test "fails when chart_digest is not sha256:<hex>" {
	sed -i.bak 's/^chart_digest=.*/chart_digest=latest/' "$LOCK"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not sha256"* ]]
}

@test "fails when the lock file is absent" {
	rm -f "$LOCK"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"lock file not found"* ]]
}
