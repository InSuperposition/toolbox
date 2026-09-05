# Exact-pin, no ranges — matches mise.toml's stance (zero `latest`,
# concrete versions everywhere). This repo's root composition, per
# CLAUDE.md § Repo Role: "a root composition applies those same modules
# as a working example and test harness."

terraform {
  required_version = "= 1.12.6" # matches mise.toml's pinned opentofu version

  required_providers {
    vault = {
      source  = "opentofu/vault"
      version = "= 5.11.0"
    }
    local = {
      source  = "opentofu/local"
      version = "= 2.9.0"
    }
  }
}
