#!/usr/bin/env bash
set -euo pipefail

# One-time, per-MACHINE OpenBao bootstrap: renders config, registers +
# starts the machine-global pitchfork daemon, inits + unseals, provisions
# Transit, stores the root token in fnox, exports the approval pubkey.
# Idempotent: safe to re-run once initialised.
#
# GitOps role: one-time bootstrap. Creates state that then lives in the OS
# keychain, the raft store, and ~/.config/pitchfork/config.toml. Never runs
# in a reconcile loop. The declarative parts (Transit engine + keys, config
# render) are `tofu`; this only orchestrates the imperative first-init that
# has no declarative form (`bao operator init`, keychain writes, the
# pitchfork global-daemon registration).
#
# ONE daemon per developer machine, not one per git worktree (ADR 0010):
# pitchfork namespaces project daemons by directory, so a per-worktree
# daemon would start a second `bao server` and lock-conflict on the shared
# raft store. Hence a *global* pitchfork daemon.
#
# The root token is stored via fnox (OS keychain, steady-state). The unseal
# key is currently printed once and NOT stored -- a known friction flaw,
# fixed by the static-seal auto-unseal change (Phase 3, CLAUDE.md
# § Deferred / TODOS.md).
#
# Test seams (bats): TOOLBOX_OPENBAO_STATE_DIR, TOOLBOX_OPENBAO_DAEMON,
# TOOLBOX_OPENBAO_LISTEN, TOOLBOX_OPENBAO_SUPERVISOR (pitchfork|none).

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

STATE_DIR="${TOOLBOX_OPENBAO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/toolbox/openbao}"
DAEMON="${TOOLBOX_OPENBAO_DAEMON:-openbao}"
LISTEN="${TOOLBOX_OPENBAO_LISTEN:-127.0.0.1:8200}"
SUPERVISOR="${TOOLBOX_OPENBAO_SUPERVISOR:-pitchfork}"
mkdir -p "$STATE_DIR"

HEALTH="http://${LISTEN}/v1/sys/health?sealedcode=200&uninitcode=200&standbycode=200"
wait_ready() {
  for _ in $(seq 1 50); do
    curl -sf -o /dev/null "$HEALTH" && return 0
    sleep 0.2
  done
  echo "OpenBao did not become reachable at $LISTEN" >&2
  return 1
}

# environments/local/main.tf reads these (test seam + the machine-global
# path); the vault provider reads VAULT_ADDR / VAULT_TOKEN.
export TF_VAR_openbao_state_dir="$STATE_DIR"
export TF_VAR_openbao_listener_address="$LISTEN"
: "${VAULT_ADDR:=http://${LISTEN}}"
export VAULT_ADDR

TFSTATE="$STATE_DIR/tofu.tfstate"
tofu_apply() {
  (cd "$REPO_ROOT/environments/local" &&
    tofu init -input=false >/dev/null &&
    tofu apply -auto-approve -input=false -state="$TFSTATE")
}

echo "==> Rendering OpenBao config (a Transit auth error here is expected)"
tofu_apply || true
test -f "$STATE_DIR/openbao.hcl" || {
  echo "config render failed -- $STATE_DIR/openbao.hcl was not created" >&2
  exit 1
}

if [ "$SUPERVISOR" = "none" ]; then
  # Test path: a plain tracked background process, no pitchfork. Keeps the
  # real ~/.config/pitchfork/config.toml pristine during bats runs.
  if ! curl -sf -o /dev/null "$HEALTH"; then
    bao server -config="$STATE_DIR/openbao.hcl" >"$STATE_DIR/bao.log" 2>&1 &
    echo $! >"$STATE_DIR/bao.pid"
  fi
  wait_ready
else
  echo "==> Registering + starting the machine-global pitchfork daemon 'global/$DAEMON'"
  if ! pitchfork daemons --global 2>/dev/null | grep -qE "(^|/)${DAEMON}([[:space:]]|$)"; then
    # Ready = the health endpoint answers, sealed or not. A `bao status`
    # readiness check would hang: a freshly-started Shamir instance is
    # sealed until this script unseals it, a step after `pitchfork start`.
    pitchfork daemons add --global "$DAEMON" \
      --run "bao server -config=$STATE_DIR/openbao.hcl" \
      --dir "$STATE_DIR" \
      --ready-http "$HEALTH" \
      --boot-start
  fi
  # No -f: force-restarting an already-leader raft instance briefly disrupts
  # it ("cannot find peer" / "Raft RPC layer closed" during re-election).
  pitchfork start "global/$DAEMON"
fi

if bao status -format=json 2>/dev/null | jq -e '.initialized == true' >/dev/null 2>&1; then
  echo "==> Already initialized -- run scripts/reset-openbao.sh first to start fresh"
else
  echo "==> Initializing (single Shamir share -- solo dev daemon, not a production ceremony)"
  init_json=$(bao operator init -key-shares=1 -key-threshold=1 -format=json)
  unseal_key=$(echo "$init_json" | jq -r '.unseal_keys_b64[0]')
  root_token=$(echo "$init_json" | jq -r '.root_token')

  bao operator unseal "$unseal_key" >/dev/null
  echo "$root_token" | fnox set VAULT_TOKEN --provider keychain
  export VAULT_TOKEN="$root_token"

  echo "==> UNSEAL KEY -- store this out-of-band NOW (a password manager, not this repo):"
  echo "    $unseal_key"
  echo "==> Root token stored via fnox. Future sessions: eval \$(fnox activate zsh)"
fi

# The 2nd apply (Transit engine + keys) authenticates as the root token.
# On an already-initialised re-run the `else` branch above never ran, so
# pull it from the keychain here.
: "${VAULT_TOKEN:=$(fnox get VAULT_TOKEN 2>/dev/null || true)}"
export VAULT_TOKEN

echo "==> Provisioning Transit engine + keys"
tofu_apply

# Export the approval key's PUBLIC half into the repo. verify-approval.sh /
# `mise run consume` verify a pinned approval attestation against THIS file
# and never call OpenBao (Codex P1-7) -- a raft-store loss stops future
# signing but leaves every past approval verifiable. Re-run this bootstrap
# (or `mise run export-approval-pubkey`) after any Transit key rotation.
echo "==> Exporting approval public key -> deploy/frontend/cosign-approval.pub"
"$REPO_ROOT/scripts/export-approval-pubkey.sh" || {
  echo "    WARNING: pubkey export failed -- OpenBao itself is fine." >&2
  echo "    Re-run: mise run export-approval-pubkey   (before mise run consume)" >&2
}

bao secrets list
bao status
