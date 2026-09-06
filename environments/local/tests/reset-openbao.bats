#!/usr/bin/env bats

# Focused coverage for scripts/reset-openbao.sh: the confirm gate, what it
# wipes vs keeps (snapshots/ = the restore bundle), and that it waits for a
# live daemon to exit before deleting its raft store.

setup() {
  SCRATCH="$(mktemp -d)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  cp -r "$REPO_ROOT/scripts" "$SCRATCH/scripts"

  export TOOLBOX_OPENBAO_STATE_DIR="$SCRATCH/state"
  export TOOLBOX_OPENBAO_DAEMON="openbao-bats-reset-$$"
  export TOOLBOX_OPENBAO_LISTEN="127.0.0.1:8397"
  export TOOLBOX_OPENBAO_SUPERVISOR="none"

  mkdir -p "$TOOLBOX_OPENBAO_STATE_DIR/data" "$TOOLBOX_OPENBAO_STATE_DIR/snapshots"
  for f in openbao.hcl seal.key root.token recovery.key tofu.tfstate; do
    : > "$TOOLBOX_OPENBAO_STATE_DIR/$f"
  done
  echo keep > "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/latest.snap"

  cd "$SCRATCH" || return 1
}

teardown() {
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid" ] &&
    kill "$(cat "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid")" 2>/dev/null || true
  pkill -f "bao server -config=$TOOLBOX_OPENBAO_STATE_DIR" 2>/dev/null || true
  cd /
  rm -rf "$SCRATCH"
}

@test "no confirmation and no TOOLBOX_OPENBAO_RESET_YES -> aborts, wipes nothing" {
  run bash -c 'printf "n\n" | ./scripts/reset-openbao.sh'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted."* ]]
  [ -d "$TOOLBOX_OPENBAO_STATE_DIR/data" ]
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/seal.key" ]
}

@test "confirmed reset wipes data/config/seal.key/root.token/recovery.key/tfstate, keeps snapshots/" {
  export TOOLBOX_OPENBAO_RESET_YES=1
  run ./scripts/reset-openbao.sh
  [ "$status" -eq 0 ]
  for f in data openbao.hcl seal.key root.token recovery.key tofu.tfstate; do
    [ ! -e "$TOOLBOX_OPENBAO_STATE_DIR/$f" ]
  done
  [ -f "$TOOLBOX_OPENBAO_STATE_DIR/snapshots/latest.snap" ]   # the restore bundle survives
}

@test "reset waits for a live daemon to exit before deleting its raft store" {
  # a real bao server holding the scratch data dir
  cat > "$TOOLBOX_OPENBAO_STATE_DIR/openbao.hcl" <<EOF
storage "raft" { path = "$TOOLBOX_OPENBAO_STATE_DIR/data"  node_id = "reset-test" }
listener "tcp" { address = "127.0.0.1:8397"  cluster_address = "127.0.0.1:0"  tls_disable = true }
disable_mlock = true
api_addr = "http://127.0.0.1:8397"
cluster_addr = "https://127.0.0.1:0"
EOF
  rm -f "$TOOLBOX_OPENBAO_STATE_DIR/seal.key"   # shamir, stays sealed — fine, we only need the process
  bao server -config="$TOOLBOX_OPENBAO_STATE_DIR/openbao.hcl" >"$TOOLBOX_OPENBAO_STATE_DIR/bao.log" 2>&1 &
  local pid=$!
  echo "$pid" > "$TOOLBOX_OPENBAO_STATE_DIR/bao.pid"
  for _ in $(seq 1 40); do curl -sf -o /dev/null "http://127.0.0.1:8397/v1/sys/health?uninitcode=200&sealedcode=200" && break; sleep 0.2; done

  export TOOLBOX_OPENBAO_RESET_YES=1
  run ./scripts/reset-openbao.sh
  [ "$status" -eq 0 ]
  ! kill -0 "$pid" 2>/dev/null       # daemon gone
  [ ! -e "$TOOLBOX_OPENBAO_STATE_DIR/data" ]
}
