# Structural coverage only — vault_policy's `policy` field is opaque HCL
# text to Terraform/OpenTofu, so ACL syntax correctness can't be checked
# offline the way local_file's rendered content can. Real syntax
# validation is a live check against a real OpenBao instance (see
# environments/local/tests/bootstrap.bats, D10/D11) — this test only
# proves the module's wiring (count, default) is correct.

mock_provider "vault" {}
mock_provider "local" {}

run "default_has_zero_policies" {
  command = plan

  variables {
    transit_keys        = [{ name = "approval-key", type = "ecdsa-p256" }]
    openbao_config_path = "openbao.hcl"
  }

  assert {
    condition     = length(vault_policy.policies) == 0
    error_message = "policies must default to empty — T3's existing usage (no policies) must stay a no-op"
  }
}

run "creates_one_policy_per_input" {
  command = plan

  variables {
    transit_keys        = [{ name = "approval-key", type = "ecdsa-p256" }]
    openbao_config_path = "openbao.hcl"
    policies = [
      { name = "chains-provenance-policy", hcl = "path \"transit/sign/chains-provenance-key\" { capabilities = [\"update\"] }" },
    ]
  }

  assert {
    condition     = length(vault_policy.policies) == 1
    error_message = "expected one vault_policy per policies entry"
  }

  assert {
    condition     = vault_policy.policies["chains-provenance-policy"].name == "chains-provenance-policy"
    error_message = "policy name did not pass through correctly"
  }
}
