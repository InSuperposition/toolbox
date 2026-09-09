#!/usr/bin/env bash
set -euo pipefail

# environments/local/scripts/openbao-cluster-bootstrap.sh — the ONE-TIME
# imperative bridge that moves the local dev OpenBao into the OrbStack
# cluster (T7c Increment 4b, docs/adr/0016,
# ~/.claude/plans/t7c-increment4-in-cluster-openbao.md).
#
# Model: environments/local/scripts/flux-bootstrap.sh — verify -> install ->
# init -> restore -> assert, nothing more. Runs ONCE per cluster and is
# disaster-recovery re-runnable (idempotent: `kubectl apply`, `tofu apply`,
# `-force` restore).
#
# It is a TRUST MIGRATION, not a fresh install: `approval-key` is NOT
# rotated. A fresh `bao operator init` mints a new signing key and every
# past approval attestation stops verifying against
# attestation/cosign-approval.pub. So the bridge does a key-preserving
# `bao operator raft snapshot restore -force` of the host daemon's store,
# then hard-fails if the in-cluster `approval-key` public half is not
# byte-identical to the committed pub file.
#
# Phase C (transit/keys/sops, the k8s-ServiceAccount auth engine, policies —
# tofu `vault_*`/`kubernetes_*` resources) lands in Increment 4c. This
# script stops after the key-preserved assertion.
#
# Test seams (openbao-cluster-bootstrap.bats):
#   TOOLBOX_OPENBAO_STATE_DIR            host state dir (seal.key, root.token, snapshots/)
#   TOOLBOX_OPENBAO_CLUSTER_KUBE_CONTEXT kube-context (default orbstack)
#   TOOLBOX_OPENBAO_CLUSTER_ENDPOINT     in-cluster HTTPS endpoint
#   TOOLBOX_OPENBAO_CLUSTER_LOCK         chart lock path (passed to the verify step)
#   TOOLBOX_OPENBAO_HOST_ADDR            host daemon addr (default http://127.0.0.1:8200)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"       # environments/local
UNIT_DIR="$ENV_DIR/openbao-cluster"

STATE_DIR="${TOOLBOX_OPENBAO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/toolbox/openbao}"
CONTEXT="${TOOLBOX_OPENBAO_CLUSTER_KUBE_CONTEXT:-orbstack}"
ENDPOINT="${TOOLBOX_OPENBAO_CLUSTER_ENDPOINT:-https://openbao.openbao.svc.cluster.local:8200}"
HOST_ADDR="${TOOLBOX_OPENBAO_HOST_ADDR:-http://127.0.0.1:8200}"
NS="openbao"
SNAP_DIR="$STATE_DIR/snapshots"
CLUSTER_DIR="$STATE_DIR/cluster"          # throwaway first-init tokens
CA_FILE="$STATE_DIR/tls/ca.crt"
TFSTATE="$STATE_DIR/openbao-cluster.tfstate"
# health probe query — 200 for every non-fatal state (sealed included) so a
# reachable-but-sealed endpoint counts as "up".
HEALTH_Q="v1/sys/health?sealedcode=200&uninitcode=200&standbycode=200&drsecondarycode=200&performancestandbycode=200"

PF_PID=""
PF_ADDR=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

# pf_refresh — (re)establish a port-forward to pod/openbao-0 and point
# VAULT_ADDR at it. Used when the direct ClusterIP endpoint is unreachable
# (a sealed pod has no ready Service endpoints; OrbStack host->ClusterIP
# routing may or may not work), and again after the pod is recreated.
pf_refresh() {
	[ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
	kc -n openbao port-forward pod/openbao-0 8200:8200 >/dev/null 2>&1 &
	PF_PID=$!
	PF_ADDR="https://127.0.0.1:8200"
	local _
	for _ in $(seq 1 50); do
		curl -sf --max-time 2 --cacert "$CA_FILE" -o /dev/null "$PF_ADDR/$HEALTH_Q" && break
		sleep 0.2
	done
	export VAULT_ADDR="$PF_ADDR"
}

die() {
	echo "openbao-cluster-bootstrap: $*" >&2
	exit 1
}
kc() { kubectl --context "$CONTEXT" "$@"; }

# The openbao chart's server StatefulSet uses `updateStrategy: OnDelete`
# (raft clusters must not roll automatically), so `kubectl rollout
# status/restart` does not apply. Poll the pod phase instead, and "restart"
# by deleting the pod (the StatefulSet controller recreates it).
wait_pod_running() {
	local _
	for _ in $(seq 1 90); do
		[ "$(kc -n "$NS" get pod openbao-0 -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && return 0
		sleep 2
	done
	die "openbao-0 did not reach Running"
}

# assert_key_preserved — the whole point of the migration. The
# attestation/ concern owns the pubkey file, so this reaches it only through
# its mise task (repo-structure.md § The concerns, ADR 0013 — never a
# cross-concern file path): `attestation:export-pubkey` re-exports
# openbao://approval-key's PUBLIC half (VAULT_ADDR/VAULT_TOKEN/VAULT_CACERT
# are exported by the caller, pointing at the in-cluster endpoint) over the
# committed attestation/cosign-approval.pub. If git then sees ANY change,
# the migration rotated the key — every past approval attestation would stop
# verifying — so restore the file and hard-fail.
assert_key_preserved() {
	local root
	root="$(git rev-parse --show-toplevel)" || die "not in a git checkout"
	(cd "$root" && mise run attestation:export-pubkey) ||
		die "could not export openbao://approval-key from $VAULT_ADDR"
	if [ -n "$(git -C "$root" status --porcelain -- attestation/cosign-approval.pub)" ]; then
		git -C "$root" checkout -- attestation/cosign-approval.pub
		{
			echo "FATAL: in-cluster approval-key does NOT match the committed pubkey."
			echo "  the migration rotated the signing key — every past approval attestation is now unverifiable."
			echo "  the in-cluster store is NOT the host's — do not repoint provider.tf."
		} >&2
		exit 1
	fi
	echo "==> approval-key preserved bit-for-bit (attestation/cosign-approval.pub unchanged)"
}

summary() {
	echo
	echo "==> In-cluster OpenBao is up and holds the original approval-key."
	echo "    endpoint : $ENDPOINT"
	echo "    CA cert  : $CA_FILE"
	echo "    tfstate  : $TFSTATE"
	echo "    Phase C (transit/keys/sops, k8s-ServiceAccount auth, policies) lands in Increment 4c."
	echo "    The host daemon + provider.tf repoint retire in Increment 4d."
}

# ── 1. preconditions (local checks first, then the cluster) ─────────────
for bin in bao helm cosign tofu kubectl crane jq flux mise; do
	command -v "$bin" >/dev/null || die "$bin not on PATH"
done
[ -s "$STATE_DIR/seal.key" ] || die "$STATE_DIR/seal.key missing — run \`mise run local:openbao:bootstrap\` first (the host daemon holds the key this migrates)"
[ -s "$STATE_DIR/root.token" ] || die "$STATE_DIR/root.token missing — host daemon not bootstrapped"
VAULT_ADDR="$HOST_ADDR" VAULT_TOKEN="$(cat "$STATE_DIR/root.token")" \
	bao status -format=json 2>/dev/null | jq -e '.initialized == true and .sealed == false' >/dev/null ||
	die "host OpenBao at $HOST_ADDR is not initialised+unsealed — start it (\`mise run local:openbao:start\`)"

kc cluster-info >/dev/null 2>&1 || die "kube-context '$CONTEXT' unreachable — is \`orb start k8s\` up?"
kc -n flux-system get helmrelease cert-manager >/dev/null 2>&1 ||
	die "cert-manager HelmRelease absent — is Flux bootstrapped and reconciling? (\`mise run local:flux:bootstrap\`)"

# ── 2. snapshot the host (the migration source of truth) ────────────────
echo "==> Snapshotting the host daemon -> $SNAP_DIR/"
VAULT_ADDR="$HOST_ADDR" VAULT_TOKEN="$(cat "$STATE_DIR/root.token")" \
	"$SCRIPT_DIR/openbao-snapshot.sh"
[ -s "$SNAP_DIR/latest.snap" ] && [ -s "$SNAP_DIR/seal.key" ] && [ -s "$SNAP_DIR/root.token" ] ||
	die "snapshot bundle incomplete under $SNAP_DIR"

# ── 3. namespace (bridge-owned — the acyclic anchor, plan § B1) ─────────
echo "==> Namespace $NS"
kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

# ── 4. TLS: wait for the cert-manager-issued leaf, read its CA ─────────
echo "==> Waiting for cert-manager to issue the openbao-tls certificate"
kc -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s >/dev/null ||
	die "cert-manager webhook not ready"
# The leaf Certificate lives in the `cert-manager-pki` Flux Kustomization
# (environments/local/cert-manager/) and only applies once ns openbao exists
# (step 3). Nudge that Kustomization, then wait.
flux --context "$CONTEXT" reconcile kustomization cert-manager-pki --timeout=2m >/dev/null 2>&1 || true
kc -n "$NS" wait --for=condition=Ready certificate/openbao-tls --timeout=180s ||
	die "openbao-tls Certificate did not become Ready — check cert-manager + the cert-manager-pki Kustomization (\`flux get kustomizations\`)"
mkdir -p "$(dirname "$CA_FILE")"
kc -n "$NS" get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d >"$CA_FILE"
[ -s "$CA_FILE" ] || die "openbao-tls Secret carried no ca.crt"

# ── 5. seal Secret from the on-machine 0600 key (never state / never a value) ──
echo "==> Seal Secret openbao-seal (from $STATE_DIR/seal.key)"
kc -n "$NS" create secret generic openbao-seal \
	--from-file=seal.key="$STATE_DIR/seal.key" \
	--dry-run=client -o yaml | kc apply -f - >/dev/null

# ── 6. verify the pinned chart (digest-equality gate) ──────────────────
echo "==> Verifying the pinned chart"
"$SCRIPT_DIR/openbao-cluster-verify.sh"

# ── 7. Phase A: the tofu-owned helm_release ────────────────────────────
echo "==> Phase A — tofu apply helm_release.openbao (state: $TFSTATE)"
export TF_VAR_kube_context="$CONTEXT"
export TF_VAR_openbao_cluster_endpoint="$ENDPOINT"
export TF_VAR_openbao_cluster_ca="$CA_FILE"
tofu -chdir="$UNIT_DIR" init -input=false >/dev/null
tofu -chdir="$UNIT_DIR" apply -auto-approve -input=false \
	-state="$TFSTATE" -target=helm_release.openbao
wait_pod_running

# ── 8. reach the endpoint (OrbStack host routing, or a port-forward) ───
export VAULT_CACERT="$CA_FILE"
if curl -sf --max-time 5 --cacert "$CA_FILE" -o /dev/null "$ENDPOINT/$HEALTH_Q"; then
	export VAULT_ADDR="$ENDPOINT"
	echo "==> Endpoint reachable directly: $ENDPOINT"
else
	echo "==> $ENDPOINT not reachable (expected while sealed / no OrbStack host routing) — port-forwarding pod/openbao-0"
	pf_refresh
fi

# ── 9. idempotency: has the migration already completed here? ──────────
bundle_token="$(cat "$SNAP_DIR/root.token")"
if bao status -format=json 2>/dev/null | jq -e '.initialized == true' >/dev/null; then
	if VAULT_TOKEN="$bundle_token" bao token lookup >/dev/null 2>&1; then
		echo "==> In-cluster OpenBao already restored (the bundle root token authenticates) — re-verifying the key"
		export VAULT_TOKEN="$bundle_token"
		rm -rf "$CLUSTER_DIR"
		assert_key_preserved
		summary
		exit 0
	fi
	echo "==> Initialised but not the migrated store — proceeding to the -force restore"
else
	echo "==> Phase B — first \`bao operator init\` (throwaway tokens)"
	mkdir -p "$CLUSTER_DIR"
	chmod 700 "$CLUSTER_DIR"
	init_json="$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)"
	umask 077
	echo "$init_json" | jq -r '.root_token' >"$CLUSTER_DIR/root.token"
	echo "$init_json" | jq -r '.recovery_keys_b64[0]' >"$CLUSTER_DIR/recovery.key"
	# auto-unseals under the mounted static key
	for _ in $(seq 1 50); do
		bao status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null && break
		sleep 0.2
	done
fi

# ── 10. key-preserving restore ────────────────────────────────────────
echo "==> Restoring the host snapshot (-force) — this preserves approval-key"
init_token="${CLUSTER_DIR}/root.token"
[ -s "$init_token" ] ||
	die "the in-cluster OpenBao is initialised but neither the bundle root token nor a first-init token authenticates against it — a half-migrated state. Recover with: kubectl --context $CONTEXT delete namespace $NS  (cascades the PVC), then re-run."
VAULT_TOKEN="$(cat "$init_token")" bao operator raft snapshot restore -force "$SNAP_DIR/latest.snap"
# the restored seal config names current_key_id=toolbox-local + the same 32
# bytes we mounted, so no key swap is needed (plan § B3 step 6 / confirm #5).
# Delete the pod so it re-reads the restored config on restart (OnDelete
# StatefulSet — the controller recreates it, static seal auto-unseals).
kc -n "$NS" delete pod openbao-0 --wait=false
sleep 3
wait_pod_running
# the old port-forward died with the old pod; re-establish if we were using one
[ -n "$PF_PID" ] && pf_refresh
for _ in $(seq 1 90); do
	bao status -format=json 2>/dev/null | jq -e '.sealed == false and .initialized == true' >/dev/null && break
	sleep 1
done
bao status -format=json | jq -e '.sealed == false' >/dev/null ||
	die "in-cluster OpenBao did not auto-unseal after the restore"

# ── 11. switch to the bundle's original identity; drop the throwaways ──
export VAULT_TOKEN="$bundle_token"
rm -rf "$CLUSTER_DIR"

# ── 12. hard assert: approval-key was preserved bit-for-bit ────────────
assert_key_preserved
summary
