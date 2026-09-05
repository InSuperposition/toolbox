# Mocks the vault provider entirely (no real OpenBao needed) to assert the
# module's non-negotiable security invariant: every Transit key it creates
# stays exportable=false / deletion_allowed=false, regardless of caller
# input. This is the regression test for that constraint — a future edit
# that quietly flips either flag to satisfy some other goal should fail
# here (Goodhart's Law guard).

mock_provider "vault" {}
mock_provider "local" {}

variables {
  transit_keys = [
    { name = "approval-key", type = "ecdsa-p256" },
    { name = "chains-provenance-key", type = "ecdsa-p256" },
  ]
  openbao_config_path = "openbao.hcl"
}

run "creates_one_key_per_input" {
  command = plan

  assert {
    condition     = length(vault_transit_secret_backend_key.keys) == 2
    error_message = "expected one vault_transit_secret_backend_key per transit_keys entry"
  }
}

run "keys_stay_non_exportable_and_undeletable" {
  command = plan

  assert {
    condition = alltrue([
      for k in vault_transit_secret_backend_key.keys : k.exportable == false
    ])
    error_message = "a Transit key was created with exportable != false — key material must never leave OpenBao"
  }

  assert {
    condition = alltrue([
      for k in vault_transit_secret_backend_key.keys : k.deletion_allowed == false
    ])
    error_message = "a Transit key was created with deletion_allowed != false — an accidental destroy must not be able to burn a signing key"
  }
}

run "rejects_empty_key_list" {
  command = plan

  variables {
    transit_keys = []
  }

  expect_failures = [var.transit_keys]
}
