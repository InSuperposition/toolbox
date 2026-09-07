#!/usr/bin/env bash
set -euo pipefail

# openbao-snapshot.sh — write a COMPLETE restore bundle to
# $STATE_DIR/snapshots/: the raft snapshot PLUS a copy of seal.key and
# root.token.
#
# The three MUST travel together. `bao operator raft snapshot restore
# -force` replaces the seal config and the token store, so the restored
# instance is sealed by the snapshot's ORIGINAL seal key and only its
# ORIGINAL root token authenticates (ADR 0011; environments/local/README.md
# § Disaster restore). A bare `.snap` on its own is not recoverable. Copy
# the whole snapshots/ directory off-machine for real disaster recovery.
#
# `mise run openbao-snapshot` calls this with no arguments. Test seam:
# TOOLBOX_OPENBAO_STATE_DIR (bats), same as openbao-bootstrap.sh.

STATE_DIR="${TOOLBOX_OPENBAO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/toolbox/openbao}"
SNAP_DIR="$STATE_DIR/snapshots"
mkdir -p "$SNAP_DIR"

bao operator raft snapshot save "$SNAP_DIR/latest.snap"
cp -f "$STATE_DIR/seal.key" "$STATE_DIR/root.token" "$SNAP_DIR/"

echo "bundle: $SNAP_DIR/{latest.snap,seal.key,root.token}"
