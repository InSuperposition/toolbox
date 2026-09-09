# Phase A providers. Both talk to the OrbStack cluster through the local
# kubeconfig; the bootstrap bridge (openbao-cluster-bootstrap.sh) exports
# TF_VAR_kube_context (+ TF_VAR_kubeconfig for a non-default path).
#
# `config_path` is explicit — the helm/kubernetes providers do NOT fall back
# to ~/.kube/config on their own ("Kubernetes cluster unreachable: no
# configuration has been provided").
#
# The Phase-C `provider "vault"` (Increment 4c) is separate — it talks to
# the in-cluster OpenBao endpoint over TLS, not to the Kubernetes API.

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
