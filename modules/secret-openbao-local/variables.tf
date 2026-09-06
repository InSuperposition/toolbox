variable "transit_keys" {
  description = "Transit signing keys to create under the shared transit/ mount. Each consumer (e.g. the digest-as-source-of-truth approval gate, later Tekton Chains provenance) adds one entry here rather than provisioning its own OpenBao instance."
  type = list(object({
    name = string
    type = string # e.g. "ecdsa-p256" — see hashicorp/vault's transit_secret_backend_key docs for valid values
  }))

  validation {
    condition     = length(var.transit_keys) > 0
    error_message = "transit_keys must name at least one key — this module exists to create Transit keys."
  }
}

variable "openbao_config_path" {
  description = "Where to render the OpenBao server config (openbao.hcl) that pitchfork's daemon command points at."
  type        = string
}

variable "openbao_data_path" {
  description = "Raft storage path for the OpenBao server (relative to wherever the pitchfork daemon's `dir` is)."
  type        = string
  default     = "openbao/data"
}

variable "openbao_snapshot_path" {
  description = "Directory `bao operator raft snapshot save` writes to (T6 backup — relative to the pitchfork daemon's `dir`). `mise run openbao-snapshot` writes `latest.snap` here; `scripts/reset-openbao.sh` deliberately preserves it. The module only creates the directory (a .gitkeep placeholder, same reason as openbao_data_path)."
  type        = string
  default     = "openbao/snapshots"
}

variable "node_id" {
  description = "Raft node identifier. Single-node local dev daemon — one fixed id is fine."
  type        = string
  default     = "openbao-local-1"
}

variable "listener_address" {
  description = "Loopback address:port the OpenBao server listens on."
  type        = string
  default     = "127.0.0.1:8200"
}

variable "cluster_address" {
  description = "Raft inter-node address:port. Required by raft's config schema even for a single-node instance."
  type        = string
  default     = "127.0.0.1:8201"
}

variable "policies" {
  description = "OpenBao access policies to create (e.g. scoping Tekton Chains' auth to only its own Transit key). Empty by default — no consumer needs this until T8."
  type = list(object({
    name = string
    hcl  = string
  }))
  default = []
}
