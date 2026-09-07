#!/usr/bin/env bats

# The load-bearing integration: mise.toml's [env] injects VAULT_TOKEN by
# reading the 0600 root.token file (ADR 0011). This proves the actual
# `mise` resolution, not just "a file exists".

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRATCH="$(mktemp -d)"
  export XDG_STATE_HOME="$SCRATCH"
  mkdir -p "$SCRATCH/toolbox/openbao"
  # mise needs the config trusted; the dev's checkout is already trusted but
  # a bats run gets a fresh HOME-independent trust for this exact path.
  mise trust "$REPO_ROOT/mise.toml" >/dev/null 2>&1 || true
}

teardown() {
  rm -rf "$SCRATCH"
}

_vault_token() {
  ( cd "$REPO_ROOT" && mise x -- sh -c 'printf %s "${VAULT_TOKEN-}"' )
}

@test "mise [env] injects VAULT_TOKEN from \$XDG_STATE_HOME/toolbox/openbao/root.token" {
  printf 'hvs.the-real-token-value' > "$SCRATCH/toolbox/openbao/root.token"
  [ "$(_vault_token)" = "hvs.the-real-token-value" ]
}

@test "mise [env] VAULT_TOKEN is empty (not an error) when root.token is absent" {
  rm -f "$SCRATCH/toolbox/openbao/root.token"
  run _vault_token
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mise [env] re-reads root.token after it changes (no stale cache for a fresh process)" {
  printf 'v1' > "$SCRATCH/toolbox/openbao/root.token"
  [ "$(_vault_token)" = "v1" ]
  printf 'v2' > "$SCRATCH/toolbox/openbao/root.token"
  [ "$(_vault_token)" = "v2" ]
}
