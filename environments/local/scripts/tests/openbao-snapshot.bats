#!/usr/bin/env bats

# environments/local/scripts/openbao-snapshot.sh — writes OpenBao's
# disaster-recovery bundle (the raft snapshot + seal.key + root.token).
# The real `bao operator raft snapshot save` needs a live
# OpenBao endpoint, so it's stubbed here (no existing fake in this repo
# implements it — the others only fake `bao status`/`bao read`); the real
# end-to-end restore claim is proven by the [k8s] chainsaw suite and the
# documented manual acceptance run, not here.

setup() {
	load helper
	SCRATCH="$(mktemp -d)"
	scratch_copy "$SCRATCH" "environments/local/scripts/openbao-snapshot.sh"
	SW="$SCRATCH/environments/local/scripts/openbao-snapshot.sh"

	export TOOLBOX_OPENBAO_STATE_DIR="$SCRATCH/state"
	STUBBIN="$SCRATCH/stubbin-bao"
	mkdir -p "$STUBBIN"
}

teardown() {
	cd /
	rm -rf "$SCRATCH"
}

# stub_bao_ok — writes bytes to the snapshot-save path argument, the way
# the real `bao operator raft snapshot save <path>` does.
stub_bao_ok() {
	cat >"$STUBBIN/bao" <<'EOF'
#!/bin/sh
if [ "$1 $2 $3" = "operator raft snapshot" ] && [ "$4" = "save" ] && [ -n "$5" ]; then
	printf 'FAKE-RAFT-SNAPSHOT-BYTES' >"$5"
	exit 0
fi
echo "fake bao: unexpected invocation: $*" >&2
exit 1
EOF
	chmod +x "$STUBBIN/bao"
}

stub_bao_fail() {
	cat >"$STUBBIN/bao" <<'EOF'
#!/bin/sh
echo "fake bao: simulated failure (sealed/unreachable)" >&2
exit 2
EOF
	chmod +x "$STUBBIN/bao"
}

seed_sources() {
	mkdir -p "$TOOLBOX_OPENBAO_STATE_DIR"
	printf 'fake-seal-key' >"$TOOLBOX_OPENBAO_STATE_DIR/seal.key"
	printf 'hvs.fake-root-token' >"$TOOLBOX_OPENBAO_STATE_DIR/root.token"
}

@test "creates snapshots/ under TOOLBOX_OPENBAO_STATE_DIR" {
	seed_sources
	stub_bao_ok
	run env PATH="$STUBBIN:$PATH" "$SW"
	[ "$status" -eq 0 ]
	[ -d "$TOOLBOX_OPENBAO_STATE_DIR/snapshots" ]
}

@test "self-heals a not-yet-existing snapshots/ dir via mkdir -p" {
	mkdir -p "$TOOLBOX_OPENBAO_STATE_DIR"
	printf 'fake-seal-key' >"$TOOLBOX_OPENBAO_STATE_DIR/seal.key"
	printf 'hvs.fake-root-token' >"$TOOLBOX_OPENBAO_STATE_DIR/root.token"
	[ ! -d "$TOOLBOX_OPENBAO_STATE_DIR/snapshots" ]
	stub_bao_ok
	run env PATH="$STUBBIN:$PATH" "$SW"
	[ "$status" -eq 0 ]
	[ -d "$TOOLBOX_OPENBAO_STATE_DIR/snapshots" ]
}

@test "fails when seal.key/root.token are missing even though bao succeeds" {
	mkdir -p "$TOOLBOX_OPENBAO_STATE_DIR"
	stub_bao_ok
	run env PATH="$STUBBIN:$PATH" "$SW"
	[ "$status" -ne 0 ]
}

@test "fails when bao operator raft snapshot save itself fails" {
	seed_sources
	stub_bao_fail
	run env PATH="$STUBBIN:$PATH" "$SW"
	[ "$status" -ne 0 ]
}

@test "success: latest.snap, seal.key, root.token all land in snapshots/ with the bundle echo" {
	seed_sources
	stub_bao_ok
	run env PATH="$STUBBIN:$PATH" "$SW"
	[ "$status" -eq 0 ]
	local snap="$TOOLBOX_OPENBAO_STATE_DIR/snapshots"
	[ -f "$snap/latest.snap" ]
	[ -f "$snap/seal.key" ]
	[ -f "$snap/root.token" ]
	[[ "$output" == *"bundle:"* ]]
	[[ "$output" == *"latest.snap,seal.key,root.token"* ]]
}

@test "permission preservation: 0600 sources retain 0600 in the copy" {
	seed_sources
	chmod 600 "$TOOLBOX_OPENBAO_STATE_DIR"/seal.key "$TOOLBOX_OPENBAO_STATE_DIR"/root.token
	stub_bao_ok
	run env PATH="$STUBBIN:$PATH" "$SW"
	[ "$status" -eq 0 ]
	[ "$(file_mode "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/seal.key")" = 600 ]
	[ "$(file_mode "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/root.token")" = 600 ]
}

@test "shellcheck-clean" {
	run shellcheck "$SW"
	[ "$status" -eq 0 ]
}
