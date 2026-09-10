#!/usr/bin/env bash
set -euo pipefail

# OpenBao state check for attestation-sign.sh — distinguishes the ways
# signing can be unavailable and prints the ONE correct fix for each. `bao
# status` alone is not enough: it proves the server is up and unsealed but
# says nothing about whether this caller can actually reach the Transit key,
# so this also does a real authenticated read of the key.
#
# The local OpenBao runs in-cluster (ADR 0016); VAULT_ADDR / VAULT_CACERT /
# VAULT_TOKEN come from mise.toml [env] (the bridge writes the token + CA).
#
# Exit 0  — reachable, unsealed, authorized, key present. Safe to sign.
# Exit 3  — any of: unreachable / uninitialised / sealed / unauthorized /
#           missing-key. stderr names which and the fix.
#
# Verify (attestation-verify.sh) NEVER calls this — it verifies against the
# committed public key and does not touch OpenBao (Codex P1-7).
#
# Usage: openbao-preflight.sh [key-name]   (default: approval-key)

KEY_NAME="${1:-approval-key}"
: "${VAULT_ADDR:=https://openbao.openbao.svc.cluster.local:8200}"
export VAULT_ADDR

die() {
	echo "openbao-preflight: $1" >&2
	echo "  fix: $2" >&2
	exit 3
}

# --- reachable? ---
# `bao status` exits 0 (unsealed), 2 (sealed), or non-0/2 (can't reach it).
status_json=""
set +e
status_json="$(bao status -format=json 2>/dev/null)"
status_rc=$?
set -e

if [ -z "$status_json" ]; then
	die "cannot reach OpenBao at $VAULT_ADDR" \
		"mise run local:openbao:bootstrap"
fi

# --- initialised? ---
# Check this BEFORE sealed: a never-initialised instance also reports
# sealed=true, and the fix (bootstrap) is different from a genuine reseal.
if [ "$(echo "$status_json" | jq -r '.initialized')" != "true" ]; then
	die "OpenBao is reachable but never initialised" \
		"mise run local:openbao:bootstrap"
fi

# --- sealed? ---
# Static-seal auto-unseal (ADR 0016): the openbao-0 pod unseals itself from
# the mounted openbao-seal Secret on every start — there is NO printed
# unseal key. A sealed initialised instance means the Secret is
# missing/wrong or the pod has not restarted since it went away.
if [ "$status_rc" -eq 2 ] || [ "$(echo "$status_json" | jq -r '.sealed')" = "true" ]; then
	die "OpenBao is sealed (static seal did not auto-unseal)" \
		"re-run mise run local:openbao:bootstrap (it re-creates the openbao-seal Secret and re-does the key-preserving -force restore from the snapshots/ bundle)"
fi

# --- authorized + key present? ---
# One authenticated read tells both apart: a permission error is auth, a
# 404-shaped error is a missing key.
if [ -z "${VAULT_TOKEN:-}" ]; then
	die "no VAULT_TOKEN in the environment" \
		"mise run local:openbao:bootstrap   (then open a new shell — mise [env] reads \$OPENBAO_STATE_DIR/root.token)"
fi
export VAULT_TOKEN

set +e
read_err="$(bao read -format=json "transit/keys/${KEY_NAME}" 2>&1 >/dev/null)"
read_rc=$?
set -e

if [ "$read_rc" -ne 0 ]; then
	case "$read_err" in
	*[Pp]ermission\ denied* | *403*)
		die "VAULT_TOKEN cannot read transit/keys/${KEY_NAME}" \
			"the token is \$OPENBAO_STATE_DIR/root.token — re-run mise run local:openbao:bootstrap if stale, or 'bao operator generate-root' with \$OPENBAO_STATE_DIR/recovery.key if it is corrupt"
		;;
	*)
		die "Transit key '${KEY_NAME}' does not exist" \
			"mise run local:openbao:bootstrap   (provisions transit/ + the approval key from environments/local/)"
		;;
	esac
fi
