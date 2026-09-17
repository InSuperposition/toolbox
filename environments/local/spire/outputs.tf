output "trust_domain" {
  description = "The SPIFFE trust domain for this cluster's SPIRE deployment."
  value       = var.trust_domain
}

output "namespace" {
  description = "Namespace spire-server / spire-agent run in."
  value       = var.namespace
}

output "release_name" {
  description = "Helm release name for the spire umbrella chart."
  value       = helm_release.spire.name
}

output "bundle_configmap_name" {
  description = "Name of the ConfigMap spire-server publishes its own trust bundle to (bundlePublisher.k8sConfigMap, format=pem, key bundle.crt) — the chart's own default name, for zot's mTLS listener to reference."
  value       = "spire-bundle"
}
