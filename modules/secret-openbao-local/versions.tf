# Exact-pin, no ranges — matches this repo's mise.toml stance (zero
# `latest`, concrete versions everywhere).

terraform {
  required_providers {
    vault = {
      source  = "opentofu/vault" # OpenTofu-registry mirror of hashicorp/vault; works against OpenBao's API-compatible endpoint
      version = "= 5.11.0"
    }
    local = {
      source  = "opentofu/local"
      version = "= 2.9.0"
    }
  }
}
