# Points at the machine-global local OpenBao daemon (one per developer
# machine, supervised as a pitchfork *global* daemon — ADR 0010) — NOT the
# deferred production `secret-openbao` module. See CLAUDE.md § Tool
# Boundaries and TODOS.md.
#
# Auth: `token` is left unset here on purpose (Zero Trust — no plaintext
# secret in repo). The vault provider's SDK falls back to the VAULT_ADDR /
# VAULT_TOKEN environment variables when `address`/`token` aren't set in
# config. Note the env var names stay VAULT_*, not OpenBao's own BAO_* CLI
# convention — the provider talks to the Vault-API-compatible HTTP API
# directly, not through the `bao` CLI, so it never looks at BAO_ADDR /
# BAO_TOKEN. The provider also has no `unix://` transport (verified), which
# is why the daemon keeps a TCP listener on 127.0.0.1:8200 rather than a
# unix socket. `mise.toml` sets VAULT_ADDR; `bootstrap-openbao.sh` sets
# VAULT_TOKEN from the OS keychain (fnox) for its own `tofu apply`.

provider "vault" {
  address = var.openbao_addr
}
