#!/usr/bin/env bash
set -euo pipefail

# T7c R1b-ii-b — host-side CA trust for the (future HTTPS-only, R1b-ii-c)
# zot registry. Two independent trust stores, both derived from the SAME
# live `toolbox-dev-ca` Secret (never a stored copy of the key — the
# Secret's `ca.crt` only):
#
#   1. `~/.docker/certs.d/<host:port>/ca.crt` — the OrbStack node's dockerd
#      trust dir (a symlink to `/mnt/mac/Users/<user>/.docker/certs.d`, R1a
#      spike finding). Read by IN-CLUSTER image pulls of the zot registry
#      itself — a plain persistent mac file, no privileged pod, no `orb
#      restart` (`orbstack-node-docker-certs-d-symlink`).
#   2. `$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt` — a concatenation of the
#      macOS system root snapshot (`/etc/ssl/cert.pem`) + the dev CA, for
#      HOST CLI calls (`mise.toml [env] SSL_CERT_FILE`). `curl` honors this
#      env var directly; several pinned Go tools (`crane`, `flux push`,
#      `cosign` without `--registry-cacert`) do NOT on this darwin
#      toolchain — see the R1b-ii-b honor-matrix in
#      `~/.claude/plans/t7c-distribution-t7d.md`. Those need a per-call
#      `--ca-file`/`--cacert`/`--registry-cacert` flag instead (R1b-ii-c
#      wires it per consumer); this script only produces the trust
#      material, not the per-tool flags.
#
# Both writes are idempotent (regenerated from source-of-truth every run,
# never appended-to) and PEM-validated before an atomic same-directory
# `mv`, so a failed run never leaves a half-written or corrupt file behind.
# Source is the CLUSTER (`kubectl get secret`), not `$OPENBAO_STATE_DIR` —
# this script has no OpenBao dependency (Codex #8).

ZOT_HOST="${TOOLBOX_ZOT_HOST:-zot.zot.svc.cluster.local:5000}"
DOCKER_CERTS_DIR="${TOOLBOX_ZOT_DOCKER_CERTS_D:-$HOME/.docker/certs.d}/$ZOT_HOST"
ZOT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/toolbox/zot"
SYSTEM_BUNDLE="${TOOLBOX_ZOT_SYSTEM_BUNDLE:-/etc/ssl/cert.pem}"

fail() {
	echo "zot-trust: $1" >&2
	exit 1
}

# ── 1. fetch the live dev CA cert (never the key — no --template on the
# key field even exists here) ────────────────────────────────────────────
dev_ca_pem="$(kubectl get secret toolbox-dev-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[ -n "$dev_ca_pem" ] || fail "toolbox-dev-ca Secret not found in ns cert-manager (is the cluster up + cert-manager-pki reconciled?) — clean-fail, no files touched"

tmp_ca="$(mktemp)"
trap 'rm -f "$tmp_ca"' EXIT
printf '%s\n' "$dev_ca_pem" >"$tmp_ca"
openssl x509 -in "$tmp_ca" -noout >/dev/null 2>&1 || fail "toolbox-dev-ca Secret's ca.crt did not parse as a valid X.509 certificate — clean-fail, no files touched"

# ── 2. node-level dockerd trust — atomic same-dir replace ───────────────
mkdir -p "$DOCKER_CERTS_DIR"
tmp_docker_ca="$(mktemp "$DOCKER_CERTS_DIR/.ca.crt.XXXXXX")"
cp "$tmp_ca" "$tmp_docker_ca"
mv -f "$tmp_docker_ca" "$DOCKER_CERTS_DIR/ca.crt"

# ── 3. host CLI trust — system snapshot + dev CA, PEM-validated,
# atomic same-dir replace ────────────────────────────────────────────────
[ -f "$SYSTEM_BUNDLE" ] || fail "$SYSTEM_BUNDLE not found — expected the macOS system root snapshot (clean-fail, no files touched)"
mkdir -p "$ZOT_STATE_DIR"
tmp_bundle="$(mktemp "$ZOT_STATE_DIR/.zot-bundle.crt.XXXXXX")"
cat "$SYSTEM_BUNDLE" "$tmp_ca" >"$tmp_bundle"
system_count="$(grep -c 'BEGIN CERTIFICATE' "$SYSTEM_BUNDLE")"
bundle_count="$(grep -c 'BEGIN CERTIFICATE' "$tmp_bundle")"
[ "$bundle_count" -eq $((system_count + 1)) ] || {
	rm -f "$tmp_bundle"
	fail "concatenated bundle has $bundle_count certificates, expected $((system_count + 1)) (system + dev CA) — clean-fail, no files touched"
}
mv -f "$tmp_bundle" "$ZOT_STATE_DIR/zot-bundle.crt"

echo "zot-trust: node trust -> $DOCKER_CERTS_DIR/ca.crt"
echo "zot-trust: host CLI trust -> $ZOT_STATE_DIR/zot-bundle.crt ($bundle_count certificates)"
