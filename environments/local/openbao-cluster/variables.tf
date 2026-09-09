# Increment 4a declares the whole skeleton's inputs; only the Phase-A
# (helm_release) ones are consumed yet. `openbao_cluster_endpoint`,
# `openbao_cluster_ca` and `transit_keys` are threaded into the Phase-C
# `provider "vault"` + `vault_*`/`kubernetes_*` resources in Increment 4c
# (they are declared now so the unit's contract is stable across the
# sub-increments and downstream `environments/local/main.tf` wiring lands
# once). OpenTofu permits a declared-but-unused variable.

# ─── Phase A (consumed in 4a) ────────────────────────────────────────────

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
  description = "Namespace the OpenBao StatefulSet runs in. The bootstrap bridge (Increment 4b) creates it (kubectl, idempotent) BEFORE this unit applies — helm_release.create_namespace stays false so tofu never owns a namespace another actor manages."
  type        = string
  default     = "openbao"
}

variable "release_name" {
  description = "Helm release name (also the StatefulSet / Service / ServiceAccount name the chart derives). Kept as `openbao` so in-cluster DNS is openbao.<namespace>.svc.cluster.local."
  type        = string
  default     = "openbao"
}

variable "chart_repository" {
  description = "OCI repository holding the OpenBao Helm chart (no chart name, no tag)."
  type        = string
  default     = "oci://ghcr.io/openbao/charts"
}

variable "chart_name" {
  description = "Helm chart name within chart_repository."
  type        = string
  default     = "openbao"
}

variable "chart_version" {
  description = "OpenBao chart version (a tag). The OpenTofu helm provider cannot pin an OCI chart by digest (hashicorp/terraform-provider-helm#1596) — it pins this tag and ignores any digest. The immutability guarantee is enforced OUT of band: openbao-cluster-verify.sh (the 4a failable check) and the bootstrap bridge (4b), before `tofu apply`, both assert `crane digest <repo>/<name>:<chart_version>` == the chart_digest recorded in openbao-cluster.lock, and fail closed on a mismatch. Bump: update this AND openbao-cluster.lock together."
  type        = string
  default     = "0.29.4"
}

variable "server_image_ref" {
  description = "OpenBao server image as `<tag>@sha256:<digest>` — passed to the chart's server.image.tag (registry+repository stay the chart defaults quay.io/openbao/openbao). kubelet pins the digest. MUST be the image the pinned chart's appVersion ships (v2.6.2) and MUST match the host daemon's version so the raft snapshot restore has no seal-config/version skew. Recorded in openbao-cluster.lock; a bump changes both."
  type        = string
  default     = "2.6.2@sha256:11fd73a2102cda9c55d5d881a8c3210303146a7ec1e8ac76f526e175c6d24641"
}

variable "seal_secret_name" {
  description = "Name of the pre-existing k8s Secret holding the 32-byte static seal key at key `seal.key`. Created by the bootstrap bridge (4b) from the on-machine 0600 $OPENBAO_STATE_DIR/seal.key — never by tofu, never from state or a helm value. Mounted read-only at /openbao/seal; openbao.hcl's `seal \"static\"` reads file:///openbao/seal/seal.key."
  type        = string
  default     = "openbao-seal"
}

variable "tls_secret_name" {
  description = "Name of the kubernetes.io/tls Secret holding the server cert + key for the HTTPS listener. Issued by cert-manager from the toolbox-dev-ca ClusterIssuer (environments/local/cert-manager/issuers.yaml). Mounted read-only at /openbao/tls."
  type        = string
  default     = "openbao-tls"
}

variable "static_seal_key_id" {
  description = "Stable identifier for the static seal key (openbao.hcl `seal \"static\"` current_key_id). MUST match the host daemon's (environments/local/main.tf sets it to `toolbox-local`) so a key-preserving raft snapshot restore unseals cleanly (plan § B3/confirm #5). It is a label, not the key."
  type        = string
  default     = "toolbox-local"
}

variable "data_storage_size" {
  description = "Size of the raft PVC (data-<release>-0) on OrbStack's default StorageClass. One voter, dev scale — 1Gi is ample."
  type        = string
  default     = "1Gi"
}

# ─── Phase C (declared now, consumed in 4c) ──────────────────────────────

variable "openbao_cluster_endpoint" {
  description = "HTTPS URL the Phase-C `provider \"vault\"` and every external client (host `bao`/`cosign`, the bridge) reach the in-cluster OpenBao at. OrbStack routes the Mac host into the cluster network so the ClusterIP DNS name resolves from the host directly."
  type        = string
  default     = "https://openbao.openbao.svc.cluster.local:8200"
}

variable "openbao_cluster_ca" {
  description = "Path to the PEM CA cert that validates the server cert at openbao_cluster_endpoint (cert-manager's dev CA, exported by the bridge to $OPENBAO_STATE_DIR/tls/ca.crt — public, no secrecy). Threaded into the Phase-C provider's `ca_cert_file` and clients' VAULT_CACERT. Empty in 4a (Phase C not wired yet)."
  type        = string
  default     = ""
}

variable "transit_keys" {
  description = "Transit signing/encryption keys to assert under the shared transit/ mount in Phase C (4c). `approval-key` (ecdsa-p256) is imported, never recreated — a recreate is a key rotation, which breaks every past approval attestation (plan § B3). `sops` (aes256-gcm96) is new, for Flux SOPS. Empty in 4a."
  type = list(object({
    name = string
    type = string
  }))
  default = []
}
