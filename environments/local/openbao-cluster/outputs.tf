# Phase C (Increment 4c). 4a/4b had no outputs (the helm_release is
# terminal). These feed Increment 4d's `environments/local/main.tf` rewire
# and the future Flux SOPS wiring (Increment 4e).

output "openbao_cluster_endpoint" {
  description = "HTTPS URL clients (host bao/cosign, Phase-C provider, later kustomize-controller) reach the in-cluster OpenBao at."
  value       = var.openbao_cluster_endpoint
}

output "transit_mount_path" {
  description = "Transit secrets engine mount path (restore-managed, not tofu-managed) — cosign's openbao://<key> scheme + `transit/decrypt/<key>` for SOPS."
  value       = "transit"
}

output "sops_key_name" {
  description = "Transit key name for Flux SOPS decryption (aes256-gcm96)."
  value       = vault_transit_secret_backend_key.sops.name
}

output "kubernetes_auth_path" {
  description = "Mount path of the Kubernetes ServiceAccount auth method (e.g. `kubernetes` → login at `auth/kubernetes/login`)."
  value       = vault_auth_backend.kubernetes.path
}

output "flux_sops_role" {
  description = "k8s-auth role name kustomize-controller logs in as to get a decrypt-only token."
  value       = vault_kubernetes_auth_backend_role.flux_sops.role_name
}

output "extra_transit_key_names" {
  description = "Names of the ADDITIONAL Transit keys created from var.transit_keys (the extension point — approval-key is never here)."
  value       = [for k in vault_transit_secret_backend_key.extra : k.name]
}
