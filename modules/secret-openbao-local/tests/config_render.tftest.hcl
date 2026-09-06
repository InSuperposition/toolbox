# Real apply — local_file has no external dependency, so this doesn't
# need the vault provider mocked at all (vault_mount/vault_transit_secret_
# backend_key still get created against a mocked vault provider so the
# plan/apply as a whole succeeds; only the rendered file content is
# asserted here).

mock_provider "vault" {}

variables {
  transit_keys = [
    { name = "approval-key", type = "ecdsa-p256" },
  ]
  openbao_config_path = "tests/tmp/openbao.hcl"
  openbao_data_path   = "custom/data/path"
  listener_address    = "127.0.0.1:9200"
}

run "renders_raft_config_with_given_inputs" {
  command = apply

  assert {
    condition     = strcontains(local_file.openbao_config.content, "storage \"raft\"")
    error_message = "rendered config must use raft storage, not the deprecated file backend"
  }

  assert {
    condition     = strcontains(local_file.openbao_config.content, "path    = \"custom/data/path\"")
    error_message = "rendered config did not pick up openbao_data_path"
  }

  assert {
    condition     = strcontains(local_file.openbao_config.content, "tls_disable = true")
    error_message = "rendered config must disable TLS on the loopback listener (dev-only daemon, not production)"
  }

  assert {
    # Checks for the directive itself (`disable_mlock =`), not the word —
    # the template's own header comment legitimately mentions
    # "disable_mlock" in prose explaining why it's omitted.
    condition     = !strcontains(local_file.openbao_config.content, "disable_mlock =")
    error_message = "disable_mlock is an obsolete no-op as of OpenBao >=2.0 (GH-363) — must not appear as a config directive"
  }
}

run "creates_the_raft_data_directory" {
  command = apply

  # raft's bolt FSM does not auto-create its storage directory (verified
  # live against a real `bao server` — see main.tf's comment). This
  # asserts the module's declarative workaround actually lands.
  assert {
    condition     = local_file.openbao_data_dir_keep.filename == "custom/data/path/.gitkeep"
    error_message = "expected a placeholder file under openbao_data_path to force the directory into existence"
  }
}

run "creates_the_snapshot_directory" {
  command = apply

  # `bao operator raft snapshot save` (T6) does not create its output dir
  # either — same declarative placeholder.
  assert {
    condition     = local_file.openbao_snapshot_dir_keep.filename == "openbao/snapshots/.gitkeep"
    error_message = "expected a placeholder under the default openbao_snapshot_path so `mise run openbao-snapshot` works on a fresh checkout"
  }
}
