output "transit_mount_path" {
  description = "Transit secrets engine mount path (used by cosign's openbao://<key> KMS scheme)."
  value       = vault_mount.transit.path
}

output "transit_key_names" {
  description = "Names of the Transit keys this module created."
  value       = [for k in vault_transit_secret_backend_key.keys : k.name]
}

output "policy_names" {
  description = "Names of the OpenBao access policies this module created."
  value       = [for p in vault_policy.policies : p.name]
}

output "openbao_config_path" {
  description = "Path the rendered openbao.hcl was written to — pass this to the pitchfork daemon's `run` command."
  value       = local_file.openbao_config.filename
}

output "openbao_snapshot_dir" {
  description = "Directory `mise run openbao-snapshot` writes raft snapshots to (T6 backup)."
  value       = var.openbao_snapshot_path
}
