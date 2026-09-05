# Transit secrets engine + the approval-key cosign signs approval
# attestations with via its native `openbao://approval-key` KMS scheme
# (https://openbao.org/blog/flux-openbao-secrets-signatures/). Key
# material never leaves OpenBao — see docs/designs/
# digest-as-source-of-truth.md, "Signing key custody: OpenBao Transit,
# not a bare keypair file".
#
# T8 (Phase 3, not yet built) adds a second, separately-scoped Transit key
# for Tekton Chains provenance signing — deliberately not this one.

resource "vault_mount" "transit" {
  path        = "transit"
  type        = "transit"
  description = "cv-frontend approval + provenance signing keys (Transit-backed, never exported)"
}

resource "vault_transit_secret_backend_key" "approval_key" {
  backend = vault_mount.transit.path
  name    = "approval-key"
  type    = "ecdsa-p256" # matches cosign's default signing algorithm

  exportable       = false # key material never leaves OpenBao (design constraint)
  deletion_allowed = false # an accidental `tofu destroy` must not be able to burn the trust boundary's key
}
