# Exact-pin, no ranges — matches this repo's mise.toml stance (zero
# `latest`, concrete versions everywhere) and environments/local/openbao's.
#
# This unit is the T7c Increment 4 in-cluster move of the local OpenBao
# (docs/adr/0015, ~/.claude/plans/t7c-increment4-in-cluster-openbao.md). It
# coexists with environments/local/openbao/ (the host daemon unit) through
# Increments 4a–4c; 4d retires that unit and renames this one back to the
# bare `openbao`. The `-cluster` suffix is only the coexistence
# disambiguator.
#
# Increment 4a is Phase A only — the `helm_release`. The Phase-C provider
# "vault" block + the vault_*/kubernetes_* resources land in 4c.

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
      source  = "opentofu/vault" # OpenTofu-registry mirror of hashicorp/vault; talks to OpenBao's API-compatible endpoint (4c)
      version = "= 5.11.0"
    }
  }
}
