output "transit_mount_path" {
  description = "Transit secrets engine mount path (used by cosign's openbao://<key> KMS scheme)."
  value       = vault_mount.transit.path
}

output "approval_key_name" {
  description = "Name of the Transit key cosign signs approval attestations with."
  value       = vault_transit_secret_backend_key.approval_key.name
}
