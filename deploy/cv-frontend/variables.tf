variable "openbao_addr" {
  description = "Address of the local pitchfork-supervised OpenBao process (see pitchfork.toml)."
  type        = string
  default     = "http://127.0.0.1:8200"
}
