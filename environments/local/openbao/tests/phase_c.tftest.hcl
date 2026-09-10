# Mocks helm / kubernetes / vault (no cluster) to assert the Phase-C
# resource graph: the SOPS key is AES + locked down, the
# decrypt policy is decrypt-ONLY, the k8s-auth role is scoped to Flux's
# kustomize-controller, and — the anti-rotation guard — `approval-key` can
# never be tofu-managed through this unit.

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "vault" {}

run "sops_key_is_aes_and_locked_down" {
  command = plan

  assert {
    condition     = vault_transit_secret_backend_key.sops.type == "aes256-gcm96"
    error_message = "the SOPS key must be aes256-gcm96 — approval-key (ecdsa-p256) cannot serve AES decryption"
  }
  assert {
    condition     = vault_transit_secret_backend_key.sops.backend == "transit"
    error_message = "the SOPS key must live under the pre-existing (restore-managed) transit mount, referenced by literal path"
  }
  assert {
    condition = alltrue([
      vault_transit_secret_backend_key.sops.exportable == false,
      vault_transit_secret_backend_key.sops.deletion_allowed == false,
    ])
    error_message = "the SOPS key must be non-exportable + undeletable, same invariant as every other Transit key"
  }
}

run "decrypt_policy_is_decrypt_only" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.flux_sops_decrypt.policy, "transit/decrypt/sops")
    error_message = "the policy must grant transit/decrypt/sops"
  }
  assert {
    condition = alltrue([
      strcontains(vault_policy.flux_sops_decrypt.policy, "capabilities = [\"update\"]"),
      !strcontains(vault_policy.flux_sops_decrypt.policy, "encrypt"),
      !strcontains(vault_policy.flux_sops_decrypt.policy, "sign"),
    ])
    error_message = "the policy must be decrypt-only — no encrypt, no sign, capabilities update"
  }
}

run "k8s_auth_role_is_scoped_to_flux" {
  command = plan

  assert {
    condition = alltrue([
      toset(vault_kubernetes_auth_backend_role.flux_sops.bound_service_account_names) == toset(["kustomize-controller"]),
      toset(vault_kubernetes_auth_backend_role.flux_sops.bound_service_account_namespaces) == toset(["flux-system"]),
    ])
    error_message = "the role must bind only kustomize-controller in flux-system"
  }
  assert {
    condition     = toset(vault_kubernetes_auth_backend_role.flux_sops.token_policies) == toset(["flux_sops_decrypt"])
    error_message = "the role must grant only the decrypt policy"
  }
}

run "same_cluster_shortcut_omits_the_reviewer_jwt" {
  command = plan

  assert {
    condition     = vault_kubernetes_auth_backend_config.this.kubernetes_host != ""
    error_message = "kubernetes_host is required even with the same-cluster shortcut"
  }
  assert {
    condition     = (vault_kubernetes_auth_backend_config.this.token_reviewer_jwt == null || vault_kubernetes_auth_backend_config.this.token_reviewer_jwt == "")
    error_message = "same-cluster shortcut: OpenBao reads its own pod SA token — do not set token_reviewer_jwt"
  }
}

run "extra_transit_keys_are_the_extension_point" {
  command = plan

  variables {
    transit_keys = [
      { name = "chains-provenance-key", type = "ecdsa-p256" },
    ]
  }

  assert {
    condition     = length(vault_transit_secret_backend_key.extra) == 1
    error_message = "one vault_transit_secret_backend_key per transit_keys entry"
  }
}

run "approval_key_can_never_be_tofu_managed" {
  command = plan

  variables {
    transit_keys = [
      { name = "approval-key", type = "ecdsa-p256" },
    ]
  }

  expect_failures = [var.transit_keys]
}
