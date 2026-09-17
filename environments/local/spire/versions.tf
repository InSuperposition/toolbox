# Exact-pin, no ranges — matches this repo's mise.toml stance (zero
# `latest`, concrete versions everywhere).
#
# SPIRE Server + Agent in-cluster — the first stage of this repo's
# workload-identity rollout. Both ship via one `helm_release` of the
# upstream `spire` umbrella chart — tofu-owned, the same
# long-lived-process-with-durable-secret test OpenBao's tofu ownership met
# (a long-lived, key-bearing process with a one-time bootstrap, not a
# Flux-helper shape).

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
    # No `vault` provider — this unit never talks to OpenBao's API
    # directly. spire-server's own vault upstreamAuthority plugin reaches
    # OpenBao at RUNTIME (k8s-auth login -> pki/root/sign-intermediate),
    # never via tofu-to-tofu state sharing.
  }
}
