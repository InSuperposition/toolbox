# Points at the local pitchfork-supervised OpenBao process (pitchfork.toml
# at repo root) — NOT the deferred production `secret-openbao` module. See
# CLAUDE.md § Tool Boundaries and TODOS.md.
#
# Auth: `token` is left unset here on purpose (Zero Trust — no plaintext
# secret in repo). The vault provider's SDK falls back to the VAULT_ADDR /
# VAULT_TOKEN environment variables when `address`/`token` aren't set in
# config. Note the env var names stay VAULT_*, not OpenBao's own BAO_* CLI
# convention — the provider talks to the Vault-API-compatible HTTP API
# directly, not through the `bao` CLI, so it never looks at BAO_ADDR /
# BAO_TOKEN. Export both before `tofu apply`:
#
#   export VAULT_ADDR=http://127.0.0.1:8200
#   export VAULT_TOKEN=<token from `bao operator init`, see README.md>
#
# That token is the same out-of-band bootstrap secret OpenBao itself
# requires (CLAUDE.md § Zero Trust: "the bootstrap secret that first
# unseals/authenticates to OpenBao is necessarily out-of-band") — it is
# never written to a file in this repo.

provider "vault" {
  address = var.openbao_addr
}
