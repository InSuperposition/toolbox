#!/usr/bin/env bash
set -euo pipefail

# openbao-snapshot.sh — write a COMPLETE restore bundle for the in-cluster
# OpenBao to $STATE_DIR/snapshots/: the raft snapshot (from the endpoint
# VAULT_ADDR/VAULT_TOKEN/VAULT_CACERT point at — mise.toml [env] targets the
# ClusterIP) PLUS a copy of the on-machine seal.key and root.token.
#
# The three MUST travel together. `bao operator raft snapshot restore
# -force` replaces the seal config and the token store, so the restored
# instance is sealed by the snapshot's ORIGINAL seal key and only its
# ORIGINAL root token authenticates (ADR 0011/0016;
# environments/local/README.md § Disaster restore). A bare `.snap` on its
# own is not recoverable. Copy the whole snapshots/ directory off-machine
# for real disaster recovery — after the host daemon's retirement this
# bundle is the ONLY genesis path (ADR 0016).
#
# `mise run local:openbao:snapshot` calls this with no arguments; the
# bootstrap bridge also calls it to refresh the bundle post-migration. Test
# seam: TOOLBOX_OPENBAO_STATE_DIR.

STATE_DIR="${TOOLBOX_OPENBAO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/toolbox/openbao}"
SNAP_DIR="$STATE_DIR/snapshots"
mkdir -p "$SNAP_DIR"

bao operator raft snapshot save "$SNAP_DIR/latest.snap"
cp -f "$STATE_DIR/seal.key" "$STATE_DIR/root.token" "$SNAP_DIR/"

echo "bundle: $SNAP_DIR/{latest.snap,seal.key,root.token}"
