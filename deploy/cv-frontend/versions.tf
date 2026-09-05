# Exact-pin, no ranges — matches this repo's mise.toml stance (zero
# `latest`, concrete versions everywhere). Bump deliberately, not via `~>`.

terraform {
  required_version = "= 1.12.6" # matches mise.toml's pinned opentofu version

  required_providers {
    vault = {
      source  = "opentofu/vault" # OpenTofu-registry mirror of hashicorp/vault; works against OpenBao's API-compatible endpoint
      version = "= 5.11.0"
    }
  }
}
