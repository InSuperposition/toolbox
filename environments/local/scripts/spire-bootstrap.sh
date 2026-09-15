#!/usr/bin/env bash
set -euo pipefail

# environments/local/scripts/spire-bootstrap.sh — the ONE-TIME bridge that
# stands up SPIRE Server + Agent in the OrbStack cluster (SPIRE Phase 1,
# TODOS.md; docs/adr/0025, docs/adr/0026).
#
# Much simpler than openbao-bootstrap.sh — no key-preserving restore.
# PR 1's Operational Lifecycle Trace already established SPIRE's CA has
# no preserve-forever invariant (nothing external is pinned against its
# intermediate cert the way attestation/cosign-approval.pub is pinned
# against approval-key): preconditions -> confirm OpenBao is up (a hard
# runtime dependency, not just a tofu one) -> namespace -> verify the
# pinned charts -> tofu apply -> wait for spire-server -> assert the
# OpenBao round-trip actually completed -> summary.
#
# Test seams (spire-bootstrap.bats):
#   TOOLBOX_SPIRE_KUBE_CONTEXT   kube-context (default orbstack)
#   TOOLBOX_SPIRE_LOCK           chart lock path (passed to the verify step)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" # environments/local
UNIT_DIR="$ENV_DIR/spire"

CONTEXT="${TOOLBOX_SPIRE_KUBE_CONTEXT:-orbstack}"
NS="spire"
TFSTATE="${TOOLBOX_SPIRE_TFSTATE:-${XDG_STATE_HOME:-$HOME/.local/state}/toolbox/spire/spire.tfstate}"

die() {
	echo "spire-bootstrap: $*" >&2
	exit 1
}
kc() { kubectl --context "$CONTEXT" "$@"; }

# wait_statefulset_ready <namespace> <name> — poll readyReplicas, same
# shape as openbao-bootstrap.sh's wait_pod_running.
wait_statefulset_ready() {
	local ns="$1" name="$2" _
	for _ in $(seq 1 90); do
		[ "$(kc -n "$ns" get statefulset "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ] && return 0
		sleep 2
	done
	die "$ns/$name did not become ready"
}

# assert_intermediate_signed — the whole point of this bridge: confirm
# spire-server's vault upstreamAuthority plugin actually completed its
# sign-intermediate round-trip against OpenBao, not just that the pod is
# Running. `spire-server bundle show` alone is NOT this proof — a proper
# SPIFFE trust bundle correctly holds only the ROOT cert regardless of
# whether the active signing CA is self-signed or upstream-issued
# (live-verified: 1 cert either way). The actual, live-verified signal
# is the CA manager's own startup log line: `self_signed=false` with a
# non-empty `upstream_authority_id` (a failed vault plugin auth crashes
# the pod outright with "Unable to rotate X509 CA" / "Fatal run error"
# before ever reaching this line — this is a real second check, not
# redundant with "pod is Running").
assert_intermediate_signed() {
	kc -n "$NS" logs spire-server-0 2>/dev/null | grep -q 'msg="X509 CA prepared".*self_signed=false.*upstream_authority_id=[^[:space:]]' ||
		die "spire-server never logged a successful upstream-signed CA rotation (self_signed=false) — the OpenBao sign-intermediate round-trip did not complete. Check: kubectl --context $CONTEXT -n $NS logs spire-server-0"
	echo "==> OpenBao round-trip confirmed — spire-server's active CA is upstream-signed, not self-signed"
}

# ── 1. preconditions ───────────────────────────────────────────────────
for bin in helm tofu kubectl; do
	command -v "$bin" >/dev/null || die "$bin not on PATH"
done

# ── 2. OpenBao is a hard runtime dependency, not just a tofu one ──────
kc cluster-info >/dev/null 2>&1 || die "kube-context '$CONTEXT' unreachable — is \`orb start k8s\` up?"
kc -n openbao get statefulset openbao >/dev/null 2>&1 ||
	die "in-cluster OpenBao not deployed — spire-server's vault upstreamAuthority plugin needs it (mise run local:openbao:bootstrap)"
[ "$(kc -n openbao get statefulset openbao -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ] ||
	die "in-cluster OpenBao is not ready (readyReplicas != 1)"

# ── 3. namespace (bridge-owned, same invariant as openbao) ────────────
echo "==> Namespace $NS"
kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

# ── 4. verify the pinned charts (digest-equality gate) ─────────────────
echo "==> Verifying the pinned charts"
"$SCRIPT_DIR/spire-verify.sh"

# ── 5. tofu apply (spire-crds, then spire) ─────────────────────────────
echo "==> tofu apply (state: $TFSTATE)"
mkdir -p "$(dirname "$TFSTATE")"
export TF_VAR_kube_context="$CONTEXT"
tofu -chdir="$UNIT_DIR" init -input=false >/dev/null
tofu -chdir="$UNIT_DIR" apply -auto-approve -input=false -state="$TFSTATE"

# ── 6. wait for spire-server, then confirm the OpenBao round-trip ─────
wait_statefulset_ready "$NS" spire-server
assert_intermediate_signed

echo
echo "==> SPIRE Server + Agent are up, OpenBao-signed."
echo "    namespace : $NS"
echo "    tfstate   : $TFSTATE"
tofu -chdir="$UNIT_DIR" output -state="$TFSTATE" 2>/dev/null | sed 's/^/    /' || true
