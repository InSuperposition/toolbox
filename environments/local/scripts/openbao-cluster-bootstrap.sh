#!/usr/bin/env bash
set -euo pipefail

# environments/local/scripts/openbao-cluster-bootstrap.sh — the ONE-TIME
# imperative bridge that moves / recovers the local dev OpenBao in the
# OrbStack cluster (T7c Increment 4, docs/adr/0016,
# ~/.claude/plans/t7c-increment4-in-cluster-openbao.md).
#
# Model: environments/local/scripts/flux-bootstrap.sh — pick source -> verify
# -> install -> init -> restore -> assert -> configure, nothing more. Runs
# ONCE per cluster and is disaster-recovery re-runnable (idempotent:
# `kubectl apply`, `tofu apply`, `-force` restore).
#
# It is a TRUST MIGRATION, not a fresh install: `approval-key` is NOT
# rotated. A fresh `bao operator init` mints a new signing key and every
# past approval attestation stops verifying against
# attestation/cosign-approval.pub. So the bridge does a key-preserving
# `bao operator raft snapshot restore -force`, then hard-fails if the
# in-cluster `approval-key` public half is not byte-identical to the
# committed pub file.
#
# Source selection (host-independent — the host daemon retires in Plan A
# O2/O3, ADR 0016):
#   host reachable (init + unsealed)  -> snapshot the host, migrate from it
#   host unreachable + a valid bundle -> restore from $SNAP_DIR (no host)
#   host unreachable + no bundle      -> the disaster case: exit, name the
#                                        recovery runbook
# A diverged host is never snapshotted over a good bundle (the host's
# approval-key must match the committed pubkey first).
#
# After the key-preserved assertion it runs Phase C (Increment 4c): the
# unit's full `tofu apply` against the RESTORED instance — the `sops`
# Transit key, the decrypt-only policy, the k8s-ServiceAccount auth method +
# role. Then it repairs the on-machine client creds ($STATE_DIR/root.token
# + seal.key) and refreshes the disaster bundle from the now-authoritative
# cluster (the host bundle omits the cluster-created `sops` key, and after a
# machine loss the external tofu state must travel with the bundle).
#
# Acceptance (manual, needs a cluster) — the Plan-A O2/O3 gate:
#   rm -rf "$OPENBAO_STATE_DIR"/{root.token,seal.key,cluster,openbao-cluster.tfstate} \
#     && kubectl --context orbstack delete namespace openbao \
#     && mise run local:openbao-cluster:bootstrap
#   asserts: restores from the off-machine $SNAP_DIR bundle with no host, the
#   original approval-key verifies, Phase C converges.
#
# Test seams (openbao-cluster-bootstrap.bats):
#   TOOLBOX_OPENBAO_STATE_DIR            state dir (seal.key, root.token, snapshots/)
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
TFSTATE_BUNDLE="$SNAP_DIR/${TFSTATE##*/}"
# health probe query — 200 for every non-fatal state (sealed included) so a
# reachable-but-sealed endpoint counts as "up".
HEALTH_Q="v1/sys/health?sealedcode=200&uninitcode=200&standbycode=200&drsecondarycode=200&performancestandbycode=200"

PF_PID=""
PF_ADDR=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

die() {
	echo "openbao-cluster-bootstrap: $*" >&2
	exit 1
}
kc() { kubectl --context "$CONTEXT" "$@"; }

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

# current_pubkey — openbao://approval-key's PUBLIC half, read straight from
# the endpoint the caller's VAULT_ADDR/VAULT_TOKEN/VAULT_CACERT point at.
# NOT via `mise run attestation:export-pubkey`: a nested `mise run`
# re-applies mise.toml's [env], which pins VAULT_ADDR at the host loopback
# and VAULT_TOKEN at the host root token — the check would silently verify
# the wrong instance (T7c Increment 4 eng review, Codex #4).
current_pubkey() { cosign public-key --key openbao://approval-key; }

# committed_pubkey — attestation/cosign-approval.pub, read in place. Reading
# a bare `attestation/` path is not a concern-climb (`../attestation/`
# would be); the bridge does the same for `git status` elsewhere.
committed_pubkey() {
	local root
	root="$(git rev-parse --show-toplevel)" || return 1
	cat "$root/attestation/cosign-approval.pub"
}

# assert_key_preserved — the whole point of the migration: the approval-key
# at $VAULT_ADDR is byte-identical to the committed pubkey. Hard fail else.
assert_key_preserved() {
	local got want
	got="$(current_pubkey)" ||
		die "could not export openbao://approval-key from $VAULT_ADDR"
	want="$(committed_pubkey)" || die "not in a git checkout"
	if [ "$got" != "$want" ]; then
		{
			echo "FATAL: approval-key at $VAULT_ADDR does NOT match the committed pubkey."
			echo "  the migration rotated the signing key — every past approval attestation is now unverifiable."
			echo "  the in-cluster store is NOT the original — do not repoint clients at it."
		} >&2
		exit 1
	fi
	echo "==> approval-key preserved bit-for-bit (matches attestation/cosign-approval.pub)"
}

# host_reachable — is the host daemon at $HOST_ADDR initialised + unsealed?
host_reachable() {
	[ -s "$STATE_DIR/root.token" ] || return 1
	VAULT_ADDR="$HOST_ADDR" VAULT_TOKEN="$(cat "$STATE_DIR/root.token")" \
		bao status -format=json 2>/dev/null | jq -e '.initialized == true and .sealed == false' >/dev/null
}

# bundle_valid — a complete restore bundle already on disk (the three files
# MUST travel together — see openbao-snapshot.sh).
bundle_valid() {
	[ -s "$SNAP_DIR/latest.snap" ] && [ -s "$SNAP_DIR/seal.key" ] && [ -s "$SNAP_DIR/root.token" ]
}

# phase_c_apply — the unit's full graph against the RESTORED instance
# (Increment 4c): the `sops` Transit key, the decrypt-only policy, the
# k8s-ServiceAccount auth method + role. Phase A (helm_release) is already
# in state so this is a no-op for it. VAULT_ADDR/VAULT_TOKEN (bundle root
# token)/VAULT_CACERT are exported by the caller. It NEVER touches the
# `transit` mount or `approval-key` (openbao-cluster-verify.sh enforces
# that, and this apply proves it).
phase_c_apply() {
	echo "==> Phase C — tofu apply (sops key, decrypt policy, k8s auth)"
	tofu -chdir="$UNIT_DIR" apply -auto-approve -input=false -state="$TFSTATE"
}

# repair_client_creds — persist the bundle's root token + seal key to
# $STATE_DIR so `mise.toml [env]`'s `cat $OPENBAO_STATE_DIR/root.token` and
# any future re-run reflect the now-authoritative cluster. The `-force`
# restore preserves both, so $SNAP_DIR's copies are the cluster's
# (Codex #1/#2 — the bridge previously only set VAULT_TOKEN in-memory).
repair_client_creds() {
	install -m 600 "$SNAP_DIR/root.token" "$STATE_DIR/root.token"
	install -m 600 "$SNAP_DIR/seal.key" "$STATE_DIR/seal.key"
}

# refresh_bundle_from_cluster — the host bundle omits the cluster-created
# `sops` key material (Phase C recreates config, not AES bytes), and after a
# machine loss the external tofu state must travel with the bundle. Re-snap
# the now-authoritative cluster and back the state up alongside it
# (Codex #5/#6). VAULT_ADDR/VAULT_TOKEN/VAULT_CACERT already point here.
refresh_bundle_from_cluster() {
	echo "==> Refreshing the disaster bundle from the in-cluster instance"
	"$SCRIPT_DIR/openbao-snapshot.sh"
	cp -f "$TFSTATE" "$TFSTATE_BUNDLE"
}

finish() {
	repair_client_creds
	refresh_bundle_from_cluster
	echo
	echo "==> In-cluster OpenBao is up, holds the original approval-key, and is API-configured."
	echo "    endpoint : $ENDPOINT"
	echo "    CA cert  : $CA_FILE"
	echo "    tfstate  : $TFSTATE  (backed up in $TFSTATE_BUNDLE)"
	tofu -chdir="$UNIT_DIR" output -state="$TFSTATE" 2>/dev/null | sed 's/^/    /' || true
	echo "    Flux SOPS wiring (--sops-vault-configmap) is deferred (Plan B / G1), gated on a named secret."
}

# ── 1. preconditions (local checks first) ─────────────────────────────
for bin in bao helm cosign tofu kubectl crane jq flux; do
	command -v "$bin" >/dev/null || die "$bin not on PATH"
done

# ── 2. pick the migration source ──────────────────────────────────────
if host_reachable; then
	echo "==> Source: the host daemon at $HOST_ADDR"
	# Codex #4 — never snapshot a diverged host over a good bundle.
	if bundle_valid; then
		host_pub="$(VAULT_ADDR="$HOST_ADDR" VAULT_TOKEN="$(cat "$STATE_DIR/root.token")" current_pubkey 2>/dev/null || true)"
		[ -n "$host_pub" ] && [ "$host_pub" = "$(committed_pubkey)" ] ||
			die "the host daemon's approval-key does not match attestation/cosign-approval.pub — refusing to overwrite the good snapshot bundle at $SNAP_DIR with a diverged store. If the host is genuinely authoritative, \`mise run attestation:export-pubkey\` + commit first."
	fi
	[ -s "$STATE_DIR/seal.key" ] || die "$STATE_DIR/seal.key missing — the host daemon holds the key this migrates"
	echo "==> Snapshotting the host daemon -> $SNAP_DIR/"
	VAULT_ADDR="$HOST_ADDR" VAULT_TOKEN="$(cat "$STATE_DIR/root.token")" \
		"$SCRIPT_DIR/openbao-snapshot.sh"
	bundle_valid || die "snapshot bundle incomplete under $SNAP_DIR"
elif bundle_valid; then
	echo "==> Source: the restore bundle at $SNAP_DIR (host daemon at $HOST_ADDR not reachable)"
else
	die "no migration source — the host daemon at $HOST_ADDR is not reachable AND there is no restore bundle at $SNAP_DIR/{latest.snap,seal.key,root.token}.

  This is the disaster case (ADR 0016 — after the host daemon retires there is no
  from-scratch bootstrap). Restore an off-machine copy of the snapshots/ bundle
  into $SNAP_DIR and re-run. If approval-key itself is unrecoverable, follow the
  'resume signing' runbook: fresh \`bao operator init\` ->
  \`mise run attestation:export-pubkey\` + commit -> re-sign the current image ->
  \`mise run frontend:deploy <image@digest> <attestation-digest>\`."
fi

# ── 3. cluster reachable + Flux reconciling cert-manager ──────────────
kc cluster-info >/dev/null 2>&1 || die "kube-context '$CONTEXT' unreachable — is \`orb start k8s\` up?"
kc -n flux-system get helmrelease cert-manager >/dev/null 2>&1 ||
	die "cert-manager HelmRelease absent — is Flux bootstrapped and reconciling? (\`mise run local:flux:bootstrap\`)"

# ── 4. namespace (bridge-owned — the acyclic anchor, plan § B1) ───────
echo "==> Namespace $NS"
kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

# ── 5. TLS: wait for the cert-manager-issued leaf, read its CA ────────
echo "==> Waiting for cert-manager to issue the openbao-tls certificate"
kc -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s >/dev/null ||
	die "cert-manager webhook not ready"
# The leaf Certificate lives in the `cert-manager-pki` Flux Kustomization
# (environments/local/cert-manager/) and only applies once ns openbao exists
# (step 4). Nudge that Kustomization, then wait.
flux --context "$CONTEXT" reconcile kustomization cert-manager-pki --timeout=2m >/dev/null 2>&1 || true
kc -n "$NS" wait --for=condition=Ready certificate/openbao-tls --timeout=180s ||
	die "openbao-tls Certificate did not become Ready — check cert-manager + the cert-manager-pki Kustomization (\`flux get kustomizations\`)"
mkdir -p "$(dirname "$CA_FILE")"
kc -n "$NS" get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d >"$CA_FILE"
[ -s "$CA_FILE" ] || die "openbao-tls Secret carried no ca.crt"

# ── 6. seal Secret from the bundle's 0600 key (never state / never a value) ──
# $SNAP_DIR/seal.key is the authoritative key for the store being restored:
# the host branch just wrote it (step 2), the bundle branch already has it.
echo "==> Seal Secret openbao-seal (from $SNAP_DIR/seal.key)"
kc -n "$NS" create secret generic openbao-seal \
	--from-file=seal.key="$SNAP_DIR/seal.key" \
	--dry-run=client -o yaml | kc apply -f - >/dev/null

# ── 7. verify the pinned chart (digest-equality gate) ────────────────
echo "==> Verifying the pinned chart"
"$SCRIPT_DIR/openbao-cluster-verify.sh"

# ── 8. Phase A: the tofu-owned helm_release ──────────────────────────
# After a machine loss the external state is gone but the release + Phase-C
# objects may still exist in-cluster; restore the state from the bundle so
# `tofu apply` converges instead of trying to re-create them (Codex #6).
if [ ! -s "$TFSTATE" ] && [ -s "$TFSTATE_BUNDLE" ]; then
	echo "==> Restoring OpenTofu state from the bundle -> $TFSTATE"
	cp -f "$TFSTATE_BUNDLE" "$TFSTATE"
fi
echo "==> Phase A — tofu apply helm_release.openbao (state: $TFSTATE)"
export TF_VAR_kube_context="$CONTEXT"
export TF_VAR_openbao_cluster_endpoint="$ENDPOINT"
export TF_VAR_openbao_cluster_ca="$CA_FILE"
tofu -chdir="$UNIT_DIR" init -input=false >/dev/null
tofu -chdir="$UNIT_DIR" apply -auto-approve -input=false \
	-state="$TFSTATE" -target=helm_release.openbao
wait_pod_running

# ── 9. reach the endpoint (OrbStack host routing, or a port-forward) ──
export VAULT_CACERT="$CA_FILE"
if curl -sf --max-time 5 --cacert "$CA_FILE" -o /dev/null "$ENDPOINT/$HEALTH_Q"; then
	export VAULT_ADDR="$ENDPOINT"
	echo "==> Endpoint reachable directly: $ENDPOINT"
else
	echo "==> $ENDPOINT not reachable (expected while sealed / no OrbStack host routing) — port-forwarding pod/openbao-0"
	pf_refresh
fi

# ── 10. idempotency: has the migration already completed here? ────────
bundle_token="$(cat "$SNAP_DIR/root.token")"
if bao status -format=json 2>/dev/null | jq -e '.initialized == true' >/dev/null; then
	if VAULT_TOKEN="$bundle_token" bao token lookup >/dev/null 2>&1; then
		echo "==> In-cluster OpenBao already restored (the bundle root token authenticates) — re-verifying the key"
		export VAULT_TOKEN="$bundle_token"
		rm -rf "$CLUSTER_DIR"
		assert_key_preserved
		phase_c_apply
		finish
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

# ── 11. key-preserving restore ───────────────────────────────────────
echo "==> Restoring the snapshot (-force) — this preserves approval-key"
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

# ── 12. switch to the bundle's original identity; drop the throwaways ──
export VAULT_TOKEN="$bundle_token"
rm -rf "$CLUSTER_DIR"

# ── 13. hard assert: approval-key was preserved bit-for-bit ───────────
assert_key_preserved

# ── 14. Phase C — API config against the restored instance (Increment 4c) ─
phase_c_apply
finish
