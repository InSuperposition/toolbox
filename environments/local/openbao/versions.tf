# Exact-pin, no ranges — matches this repo's mise.toml stance (zero
# `latest`, concrete versions everywhere).
#
# The in-cluster local OpenBao (docs/adr/0016). Phase A is the
# `helm_release`; Phase C is the `provider "vault"` block + the `vault_*`
# API config, applied by the bootstrap bridge after the key-preserving
# snapshot restore.

terraform {
  required_version = "= 1.12.6" # matches mise.toml's pinned opentofu version

  required_providers {
    helm = {
      source  = "opentofu/helm"
      version = "= 3.3.0"
    }
    kubernetes = {
      source  = "opentofu/kubernetes"
      version = "= 3.2.1"
    }
    vault = {
      source  = "opentofu/vault" # OpenTofu-registry mirror of hashicorp/vault; talks to OpenBao's API-compatible endpoint
      version = "= 5.11.0"
    }
  }
}
