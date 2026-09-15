#!/usr/bin/env bats

# environments/local/scripts/openbao-verify.sh — the chart-pin gate. The
# guard must FAIL closed on a mutated digest / broken lock, not only pass
# on the committed one.
#
# Most cases run against a local, throwaway TLS zot registry
# (tests/lib/registry.bash's start_registry_tls) instead of live
# ghcr.io/quay.io — no network, no TOCTOU (the old `online()` probe ran a
# SEPARATE `oras resolve` before the script's own, a race the registry
# could change between). The lock-integrity cases (missing field, bad
# digest format, missing file) and the anti-rotation guard need no
# registry at all — the guard runs BEFORE any network call in the script
# (moved there this same pass; it used to run last and could be silently
# skipped by an earlier registry-down exit). Only the original
# happy-path case ("passes on the committed lock") stays live/network-
# gated — this item's own scope is error-path tests, not the happy path.

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" \
		"environments/local/openbao" \
		"environments/local/scripts/openbao-verify.sh"
	: >"$SCRATCH/mise.toml"
	SW="$SCRATCH/environments/local/scripts/openbao-verify.sh"
	LOCK="$SCRATCH/environments/local/openbao/openbao.lock"
}

teardown() {
	[ -n "${REG_TLS:-}" ] && stop_registry_tls "$SCRATCH"
	cd /
	rm -rf "$SCRATCH"
}

online() {
	# Both refs the script itself depends on — a chart-only check let a
	# quay.io-only outage pass this gate while the script's own image-digest
	# call skipped internally, falsely failing "fails closed on a mutated
	# image digest" (found 2026-09-14, fixed here alongside the oras swap).
	oras resolve ghcr.io/openbao/charts/openbao:0.29.4 >/dev/null 2>&1 &&
		oras resolve quay.io/openbao/openbao:2.6.2 >/dev/null 2>&1
}

# write_lock <chart_repo> <chart_name> <chart_version> <chart_digest> \
#            <image_ref> <image_tag> <image_digest> — overwrites $LOCK
# with exactly the fields openbao-verify.sh reads (val()); static_seal_key_id
# is a fixed placeholder, irrelevant to every case below (none reach the
# render step except via push_local_fixture's real, matching digests).
write_lock() {
	cat >"$LOCK" <<EOF
chart_repository=$1
chart_name=$2
chart_version=$3
chart_digest=$4
image_ref=$5
image_tag=$6
image_digest=$7
static_seal_key_id=toolbox-local
EOF
}

# push_local_fixture — start a local TLS zot, push a chart-shaped and an
# image-shaped artifact, and write a fully-correct openbao.lock pointing
# at them (both digests real and matching). Exports TOOLBOX_ORAS_CACERT
# at the fixture's own CA so the script trusts it. Sets CHART_DIGEST /
# IMAGE_DIGEST so a test can mutate exactly one field afterward, the same
# "start from a known-good lock, corrupt one field" shape the old
# live-network cases used.
push_local_fixture() {
	start_registry_tls "$SCRATCH"
	export TOOLBOX_ORAS_CACERT="$TLS_CA"

	# relative filenames + cd — oras push rejects an absolute artifact path
	# by default (matches the convention tests/lib/registry.bash's own
	# make_image() already uses).
	echo "chart bytes $(date +%s%N)" >"$SCRATCH/chart.bin"
	(cd "$SCRATCH" && oras push --ca-file "$TLS_CA" "${REG_TLS}/chart:1.0.0" \
		"chart.bin:application/octet-stream" >/dev/null)
	CHART_DIGEST="$(oras resolve --ca-file "$TLS_CA" "${REG_TLS}/chart:1.0.0")"

	echo "image bytes $(date +%s%N)" >"$SCRATCH/image.bin"
	(cd "$SCRATCH" && oras push --ca-file "$TLS_CA" "${REG_TLS}/image:2.0.0" \
		"image.bin:application/octet-stream" >/dev/null)
	IMAGE_DIGEST="$(oras resolve --ca-file "$TLS_CA" "${REG_TLS}/image:2.0.0")"

	write_lock "oci://${REG_TLS}" "chart" "1.0.0" "$CHART_DIGEST" \
		"${REG_TLS}/image" "2.0.0" "$IMAGE_DIGEST"
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

@test "fails closed on a mutated chart digest (local registry, no live network)" {
	push_local_fixture
	sed -i.bak 's/^chart_digest=.*/chart_digest=sha256:0000000000000000000000000000000000000000000000000000000000000000/' "$LOCK"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"resolves to"* ]]
}

@test "fails closed on a mutated image digest (local registry, no live network)" {
	push_local_fixture
	sed -i.bak 's/^image_digest=.*/image_digest=sha256:1111111111111111111111111111111111111111111111111111111111111111/' "$LOCK"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"resolves to"* ]]
}

@test "fails closed (dies, not skip) on a cert verification failure" {
	start_registry_tls "$SCRATCH"
	# TOOLBOX_ORAS_CACERT deliberately left unset: the fixture's
	# self-signed cert is untrusted by the system store, so oras's TLS
	# handshake fails before it ever reaches the (nonexistent) artifact.
	write_lock "oci://${REG_TLS}" "chart" "1.0.0" \
		"sha256:0000000000000000000000000000000000000000000000000000000000000000" \
		"${REG_TLS}/image" "2.0.0" \
		"sha256:1111111111111111111111111111111111111111111111111111111111111111"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not a network issue"* ]]
	[[ "$output" != *"skipping"* ]]
}

@test "fails closed (dies, not skip) on a malformed chart ref" {
	# a bad tag — invalid reference syntax, a pure client-side parse error
	# oras rejects before ever attempting a connection (live-verified: the
	# same malformed tag against a dead port still reports the parse
	# error, never a dial error). No registry needed.
	write_lock "oci://127.0.0.1:1" "chart" "bad::tag" \
		"sha256:0000000000000000000000000000000000000000000000000000000000000000" \
		"127.0.0.1:1/image" "2.0.0" \
		"sha256:1111111111111111111111111111111111111111111111111111111111111111"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not a network issue"* ]]
	[[ "$output" != *"skipping"* ]]
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

@test "anti-rotation guard: fails if the unit tofu-manages the transit mount" {
	# runs before any network call now — no online()/registry needed.
	printf '\nresource "vault_mount" "x" { path = "transit" }\n' \
		>>"$SCRATCH/environments/local/openbao/main.tf"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"restore-managed"* ]]
}

@test "anti-rotation guard: fails if the unit tofu-manages approval-key" {
	printf '\nresource "vault_transit_secret_backend_key" "x" {\n  backend = "transit"\n  name    = "approval-key"\n  type    = "ecdsa-p256"\n}\n' \
		>>"$SCRATCH/environments/local/openbao/main.tf"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"restore-managed"* ]]
}

@test "anti-rotation guard runs before the anti-rotation guard's own network dependency ever exists" {
	# regression guard for the reordering itself: a completely broken lock
	# (missing file) would normally die at the lock-existence check, which
	# now runs AFTER the guard — so a tofu-managed transit mount is still
	# caught even then, proving the guard is truly first, not just early.
	rm -f "$LOCK"
	printf '\nresource "vault_mount" "x" { path = "transit" }\n' \
		>>"$SCRATCH/environments/local/openbao/main.tf"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"restore-managed"* ]]
	[[ "$output" != *"lock file not found"* ]]
}

@test "shellcheck-clean" {
	run shellcheck "$SW"
	[ "$status" -eq 0 ]
}

# classify_failure() unit tests — the script has no source-safe entry
# point, so the function body is extracted into its own snippet (same
# technique as openbao-bootstrap.bats's bao_reachable() tests) and
# exercised directly against real error text. The transient/not-found
# cases and the malformed-ref/cert-failure cases are also proven
# end-to-end above; auth-failure is unit-tested only — oras's real 401
# response text is live-verified here, but a live authenticated fixture
# would need bcrypt (the external `htpasswd` binary — an undeclared
# system dependency this repo's mise-pinned toolchain doesn't have).
setup_classify_failure() {
	local snippet="$SCRATCH/classify_failure.sh"
	sed -n '/^classify_failure() {/,/^}/p' "$SW" >"$snippet"
	[ -s "$snippet" ]
	CLASSIFY_SNIPPET="$snippet"
}

run_classify() {
	env bash -c "source '$CLASSIFY_SNIPPET'; classify_failure \"\$1\"" _ "$1"
}

@test "classify_failure: real not-found text skips (transient)" {
	setup_classify_failure
	run run_classify 'Error response from registry: failed to resolve digest: 127.0.0.1:9999/nope:missing: not found'
	[ "$status" -ne 0 ]
}

@test "classify_failure: real connection-refused text skips (transient)" {
	setup_classify_failure
	run run_classify 'Error: failed to resolve digest: Head "http://127.0.0.1:1/v2/x/manifests/y": dial tcp 127.0.0.1:1: connect: connection refused'
	[ "$status" -ne 0 ]
}

@test "classify_failure: real DNS-lookup-failure text skips (transient)" {
	setup_classify_failure
	run run_classify 'Error: failed to resolve digest: Head "https://x.invalid/v2/x/manifests/y": dial tcp: lookup x.invalid: no such host'
	[ "$status" -ne 0 ]
}

@test "classify_failure: real malformed-ref text dies (not transient)" {
	setup_classify_failure
	run run_classify 'Error: "127.0.0.1:1/chart:bad::tag": invalid reference: invalid tag "bad::tag"'
	[ "$status" -eq 0 ]
}

@test "classify_failure: real cert-verification-failure text dies (not transient)" {
	setup_classify_failure
	run run_classify 'Error: failed to resolve digest: Head "https://127.0.0.1:9999/v2/x/manifests/y": tls: failed to verify certificate: x509: certificate signed by unknown authority'
	[ "$status" -eq 0 ]
}

@test "classify_failure: real auth-failure text dies (not transient)" {
	setup_classify_failure
	run run_classify 'Error: failed to resolve digest: basic credential not found
Please check whether the registry credential stored in the authentication file at "/root/.docker/config.json" is correct'
	[ "$status" -eq 0 ]
}
