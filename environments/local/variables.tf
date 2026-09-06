variable "openbao_state_dir" {
  description = "Where the OpenBao daemon's rendered config, raft store and snapshots are written. Test seam (bats sets TF_VAR_openbao_state_dir); null falls back to ~/.local/state/toolbox/openbao."
  type        = string
  default     = null
}

variable "openbao_listener_address" {
  description = "Loopback address:port the machine-global OpenBao daemon listens on. Also the vault provider's address (see provider.tf). Test seam so bats can run on a spare port."
  type        = string
  default     = "127.0.0.1:8200"
}
