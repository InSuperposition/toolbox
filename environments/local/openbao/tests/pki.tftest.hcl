# Mocks helm / kubernetes / vault (no cluster) to assert the PKI mount's
# resource graph: the root key never leaves OpenBao, the sign-intermediate
# policy is scoped to exactly that one path, and the k8s-auth role grants
# only that policy to the future spire-server ServiceAccount.

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "vault" {}

run "pki_mount_is_a_pki_backend" {
  command = plan

  assert {
    condition     = vault_mount.pki.type == "pki"
    error_message = "the mount type must be pki"
  }
}

run "root_key_never_leaves_openbao" {
  command = plan

  assert {
    condition     = vault_pki_secret_backend_root_cert.spire_root.type == "internal"
    error_message = "the root cert's private key must be generated internal to OpenBao and never exported — 'exported'/'kms' are not allowed here"
  }
  assert {
    condition     = vault_pki_secret_backend_root_cert.spire_root.backend == "pki"
    error_message = "the root cert must live under the pki mount, referenced by literal path"
  }
}

run "sign_intermediate_policy_is_scoped_to_exactly_that_path" {
  command = plan

  assert {
    condition = alltrue([
      strcontains(vault_policy.spire_sign_intermediate.policy, "pki/root/sign-intermediate"),
      strcontains(vault_policy.spire_sign_intermediate.policy, "capabilities = [\"update\"]"),
    ])
    error_message = "the policy must grant pki/root/sign-intermediate, capability update"
  }
  assert {
    condition = alltrue([
      !strcontains(vault_policy.spire_sign_intermediate.policy, "pki/issue"),
      !strcontains(vault_policy.spire_sign_intermediate.policy, "pki/root/generate"),
      !strcontains(vault_policy.spire_sign_intermediate.policy, "transit"),
    ])
    error_message = "the policy must be scoped to sign-intermediate only — no issue, no root generation, no transit"
  }
}

run "k8s_auth_role_is_scoped_to_spire_server" {
  command = plan

  assert {
    condition = alltrue([
      toset(vault_kubernetes_auth_backend_role.spire_server.bound_service_account_names) == toset(["spire-server"]),
      toset(vault_kubernetes_auth_backend_role.spire_server.bound_service_account_namespaces) == toset(["spire"]),
    ])
    error_message = "the role must bind only spire-server in ns spire"
  }
  assert {
    condition     = toset(vault_kubernetes_auth_backend_role.spire_server.token_policies) == toset(["spire_sign_intermediate"])
    error_message = "the role must grant only the spire_sign_intermediate policy — never flux_sops_decrypt or chains_provenance_sign"
  }
}
