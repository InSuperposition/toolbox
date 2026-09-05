output "transit_mount_path" {
  description = "Transit secrets engine mount path (used by cosign's openbao://<key> KMS scheme)."
  value       = module.secret_openbao_local.transit_mount_path
}

output "transit_key_names" {
  description = "Names of the Transit keys provisioned in the local OpenBao instance."
  value       = module.secret_openbao_local.transit_key_names
}
