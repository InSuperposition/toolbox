#!/usr/bin/env bats

# The load-bearing integration: mise.toml's [env] injects VAULT_TOKEN by
# reading the 0600 root.token file (ADR 0011). This proves the actual
# `mise` resolution, not just "a file exists".

setup() {
  load helper
  REPO_ROOT="$(toolbox_repo_root)"
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

_ssl_cert_file() {
  ( cd "$REPO_ROOT" && mise x -- sh -c 'printf %s "${SSL_CERT_FILE-}"' )
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

@test "mise [env] SSL_CERT_FILE points at \$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt when it exists" {
  mkdir -p "$SCRATCH/toolbox/zot"
  printf 'fake bundle' > "$SCRATCH/toolbox/zot/zot-bundle.crt"
  [ "$(_ssl_cert_file)" = "$SCRATCH/toolbox/zot/zot-bundle.crt" ]
}

@test "mise [env] SSL_CERT_FILE falls back to a real OS trust-store file (never empty) when zot-bundle.crt is absent" {
  # A bug shipped and caught live (T7c R1b-ii-b): mise ALWAYS exports a key
  # declared in [env], even an empty-string template result — and SSL_CERT_FILE
  # is a convention `hk` itself reads to build its own HTTP client, which
  # crashes outright ("Error loading CA root certificate ... at ''") the
  # instant it's set to "". This must never be empty — it either points at
  # the dev bundle or falls back to a real, existing system trust-store
  # snapshot, but it is NEVER a blank/missing path.
  rm -f "$SCRATCH/toolbox/zot/zot-bundle.crt"
  run _ssl_cert_file
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -f "$output" ]
}
