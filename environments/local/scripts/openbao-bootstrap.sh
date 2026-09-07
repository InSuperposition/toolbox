#!/usr/bin/env bash
set -euo pipefail

# One-time, per-MACHINE OpenBao bootstrap: writes the static-seal key,
# renders config, registers + starts the machine-global pitchfork daemon,
# initialises (auto-unseals), provisions Transit, writes the root + recovery
# keys as 0600 files, exports the approval pubkey. Idempotent: safe to re-run.
#
# GitOps role: one-time bootstrap. Creates state that then lives in the raft
# store, $STATE_DIR/{seal.key,root.token,recovery.key}, and
# ~/.config/pitchfork/config.toml. Never runs in a reconcile loop. The
# declarative parts (Transit engine + keys, config render) are `tofu`; this
# only orchestrates the imperative first-init that has no declarative form
# (`bao operator init`, the secret-file writes, the pitchfork global-daemon
# registration).
#
# ONE daemon per developer machine, not one per git worktree (ADR 0010):
# pitchfork namespaces project daemons by directory, so a per-worktree
# daemon would start a second `bao server` and lock-conflict on the shared
# raft store. Hence a *global* pitchfork daemon.
#
# All secrets are 0600 files next to the raft store (ADR 0011): no keychain,
# no fnox. `openbao.hcl` reads seal.key via `file://` (so a boot-start daemon
# unseals before the login keychain would even be relevant); `mise [env]`
# injects VAULT_TOKEN by `cat`-ing root.token. `bao operator init` also
# yields a recovery key -- kept as recovery.key for `bao operator
# generate-root` if root.token is ever lost/corrupt (the one non-destructive
# recovery; `reset` rotates the Transit key).
#
# Test seams (bats): TOOLBOX_OPENBAO_STATE_DIR, TOOLBOX_OPENBAO_DAEMON,
# TOOLBOX_OPENBAO_LISTEN, TOOLBOX_OPENBAO_SUPERVISOR (pitchfork|none).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"        # environments/local/scripts
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"            # environments/local — the tofu root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"    # repo root — for deploy/frontend (P4 drops this)
# shellcheck source=/dev/null  # lib is bats-tested directly (openbao-bootstrap.bats)
. "$SCRIPT_DIR/lib/openbao.sh"

STATE_DIR="${TOOLBOX_OPENBAO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/toolbox/openbao}"
DAEMON="${TOOLBOX_OPENBAO_DAEMON:-openbao}"
LISTEN="${TOOLBOX_OPENBAO_LISTEN:-127.0.0.1:8200}"
SUPERVISOR="${TOOLBOX_OPENBAO_SUPERVISOR:-pitchfork}"
mkdir -p "$STATE_DIR"

HEALTH="http://${LISTEN}/v1/sys/health?sealedcode=200&uninitcode=200&standbycode=200"

# environments/local/main.tf reads these (test seam + the machine-global
# path); the vault provider reads VAULT_ADDR / VAULT_TOKEN.
export TF_VAR_openbao_state_dir="$STATE_DIR"
export TF_VAR_openbao_listener_address="$LISTEN"
: "${VAULT_ADDR:=http://${LISTEN}}"
export VAULT_ADDR

TFSTATE="$STATE_DIR/tofu.tfstate"
tofu_apply() {
  (cd "$ENV_DIR" &&
    tofu init -input=false >/dev/null &&
    tofu apply -auto-approve -input=false -state="$TFSTATE")
}

echo "==> Rendering OpenBao config (a Transit auth error here is expected)"
tofu_apply || true
test -f "$STATE_DIR/openbao.hcl" || {
  echo "config render failed -- $STATE_DIR/openbao.hcl was not created" >&2
  exit 1
}

# Static-seal key: raw 32 bytes, 0600, next to the raft store. `file://` in
# openbao.hcl. Generated once; a re-run keeps the existing key (rotating it
# would strand the sealed data).
if [ ! -s "$STATE_DIR/seal.key" ]; then
  write_secret_file "$STATE_DIR/seal.key" "$(openssl rand 32 | base64)"
  # base64 so the value round-trips through printf without NULs; openbao's
  # file:// seal accepts base64.
fi

if [ "$SUPERVISOR" = "none" ]; then
  # Test path: a plain tracked background process, no pitchfork. Keeps the
  # real ~/.config/pitchfork/config.toml pristine during bats runs.
  if ! curl -sf -o /dev/null "$HEALTH"; then
    bao server -config="$STATE_DIR/openbao.hcl" >"$STATE_DIR/bao.log" 2>&1 &
    echo $! >"$STATE_DIR/bao.pid"
  fi
  openbao_wait_ready "$LISTEN"
else
  echo "==> Registering + starting the machine-global pitchfork daemon 'global/$DAEMON'"
  if ! pitchfork daemons --global 2>/dev/null | grep -qE "(^|/)${DAEMON}([[:space:]]|$)"; then
    # Ready = the health endpoint answers (sealedcode/uninitcode 200 covers
    # the brief window between process start and static-seal auto-unseal).
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
  echo "==> Initializing (static seal auto-unseals; single recovery share -- solo dev daemon)"
  init_json=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
  write_secret_file "$STATE_DIR/root.token" "$(echo "$init_json" | jq -r '.root_token')"
  write_secret_file "$STATE_DIR/recovery.key" "$(echo "$init_json" | jq -r '.recovery_keys_b64[0]')"
  echo "==> root.token + recovery.key + seal.key written to $STATE_DIR (0600)."
fi

# Authenticate the rest of the script (2nd tofu apply, pubkey export) as the
# root token FROM THIS instance's file -- unconditionally, never inheriting a
# VAULT_TOKEN from the parent env (a scratch bootstrap under `mise run check`
# would otherwise carry the real daemon's token and 403 against :8399).
VAULT_TOKEN="$(cat "$STATE_DIR/root.token")"
export VAULT_TOKEN

echo "==> Provisioning Transit engine + keys"
tofu_apply

# Export the approval key's PUBLIC half into the repo. verify-approval.sh /
# `mise run consume` verify a pinned approval attestation against THIS file
# and never call OpenBao (Codex P1-7) -- a raft-store loss stops future
# signing but leaves every past approval verifiable. Same one line as
# `mise run export-approval-pubkey` (inlined, not called -- a script must
# not invoke a mise task that sits on its own call path, CLAUDE.md § mise).
# cosign 3.1.3: openbao:// and hashivault:// are the same KMS plugin.
echo "==> Exporting approval public key -> deploy/frontend/cosign-approval.pub"
mkdir -p "$REPO_ROOT/deploy/frontend"
cosign public-key --key openbao://approval-key \
  --outfile "$REPO_ROOT/deploy/frontend/cosign-approval.pub" || {
  echo "    WARNING: pubkey export failed -- OpenBao itself is fine." >&2
  echo "    Re-run: mise run export-approval-pubkey   (before mise run consume)" >&2
}

bao secrets list
bao status

echo
echo "==> Done. VAULT_TOKEN comes from mise [env] (reads root.token). If your"
echo "    current shell was activated before this bootstrap and shows an empty"
echo "    VAULT_TOKEN, open a new shell or run 'mise env'."
