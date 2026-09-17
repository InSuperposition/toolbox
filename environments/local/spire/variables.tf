# The bootstrap bridge sets the cluster-specific `TF_VAR_*` (`kube_context`,
# `openbao_endpoint`); the rest default to the dev shape.

variable "kube_context" {
  description = "kubeconfig context for the helm + kubernetes providers. The bootstrap bridge sets TF_VAR_kube_context; `mise run check`'s offline tofu-validate/test never reaches a cluster (mock_provider)."
  type        = string
  default     = "orbstack"
}

variable "kubeconfig" {
  description = "Path to the kubeconfig for the helm + kubernetes providers. Explicit — the providers do not default to ~/.kube/config. The `~` is expanded by the providers."
  type        = string
  default     = "~/.kube/config"
}

variable "namespace" {
  description = "Namespace spire-server / spire-agent run in. The bootstrap bridge creates it (kubectl, idempotent) BEFORE this unit applies — helm_release.create_namespace stays false so tofu never owns a namespace another actor manages."
  type        = string
  default     = "spire"
}

variable "release_name" {
  description = "Helm release name for the `spire` umbrella chart."
  type        = string
  default     = "spire"
}

variable "chart_repository" {
  description = "Classic (non-OCI) Helm repository holding the spire-crds and spire charts. No chart name, no version."
  type        = string
  default     = "https://spiffe.github.io/helm-charts-hardened/"
}

variable "spire_crds_chart_version" {
  description = "spire-crds chart version. Bump: update this AND spire.lock's spire_crds_chart_digest together, then re-run mise run local:spire:verify."
  type        = string
  default     = "0.6.1"
}

variable "spire_chart_version" {
  description = "spire (umbrella) chart version. Bump: update this AND spire.lock's spire_chart_digest together, then re-run mise run local:spire:verify."
  type        = string
  default     = "0.30.2"
}

variable "trust_domain" {
  description = "The SPIFFE trust domain for this cluster's SPIRE deployment. Used consistently across global.spire.trustDomain, zot's future uriSanPattern (once zot's mTLS SAN pattern is wired up), and registration entries."
  type        = string
  default     = "toolbox.local"
}

variable "openbao_endpoint" {
  description = "HTTPS URL spire-server's vault upstreamAuthority plugin reaches the in-cluster OpenBao at. Same value as environments/local/openbao's own var.openbao_endpoint — duplicated by value, not by cross-unit reference (the two units never share tofu state)."
  type        = string
  default     = "https://openbao.openbao.svc.cluster.local:8200"
}

variable "spire_ca_configmap_name" {
  description = "Name of the ConfigMap (in this unit's namespace) holding the PEM CA cert spire-server uses to verify OpenBao's TLS listener. Published by the dedicated trust-manager Bundle CR (environments/local/trust-manager/spire-vault-ca.yaml) — trust-manager names the per-namespace target ConfigMap after Bundle.metadata.name (confirmed live against the existing toolbox-ca-bundle Bundle)."
  type        = string
  default     = "spire-vault-ca"
}

variable "data_storage_size" {
  description = "Size of spire-server's PVC (sqlite3 datastore + disk keyManager) on OrbStack's default StorageClass. Dev scale — 1Gi is ample."
  type        = string
  default     = "1Gi"
}
