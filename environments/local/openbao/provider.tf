# Phase A providers. Both talk to the OrbStack cluster through the local
# kubeconfig; the bootstrap bridge (openbao-bootstrap.sh) exports
# TF_VAR_kube_context (+ TF_VAR_kubeconfig for a non-default path).
#
# `config_path` is explicit — the helm/kubernetes providers do NOT fall back
# to ~/.kube/config on their own ("Kubernetes cluster unreachable: no
# configuration has been provided").
#
provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig
    config_context = var.kube_context
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig
  config_context = var.kube_context
}

# Phase C — talks to the in-cluster OpenBao HTTP API over TLS, not to the
# Kubernetes API.
#
# `token` is deliberately unset (Zero Trust — no plaintext secret in repo or
# state). The vault provider's SDK falls back to VAULT_ADDR / VAULT_TOKEN /
# VAULT_CACERT env vars; the bootstrap bridge exports them (VAULT_TOKEN = the
# snapshot bundle's ORIGINAL root token, post-restore) before its final
# `tofu apply`. `mise run check`'s offline `tofu validate`/`test` never
# reach it (mock_provider).
provider "vault" {
  address      = var.openbao_endpoint
  ca_cert_file = var.openbao_ca != "" ? var.openbao_ca : null
}
