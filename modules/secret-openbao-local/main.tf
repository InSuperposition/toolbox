# Transit secrets engine + one or more signing keys, plus the rendered
# OpenBao server config the caller's pitchfork daemon runs against. Keys
# are Transit-backed by design — material never leaves OpenBao, cosign
# signs via its native `openbao://<key>` KMS scheme
# (https://openbao.org/blog/flux-openbao-secrets-signatures/).
#
# NOT the deferred production `secret-openbao` module — see README.md and
# CLAUDE.md § Tool Boundaries. This module's OpenBao is a single-node,
# pitchfork-supervised local dev daemon.

resource "vault_mount" "transit" {
  path        = "transit"
  type        = "transit"
  description = "Local dev signing keys (Transit-backed, never exported)"
}

resource "vault_transit_secret_backend_key" "keys" {
  for_each = { for k in var.transit_keys : k.name => k }

  backend = vault_mount.transit.path
  name    = each.value.name
  type    = each.value.type

  # Non-negotiable regardless of caller input — see tests/keys.tftest.hcl.
  exportable       = false # key material never leaves OpenBao
  deletion_allowed = false # an accidental `tofu destroy` must not be able to burn a signing key
}

resource "vault_policy" "policies" {
  # Empty by default (T3 has no consumer for this yet) — T8 (Tekton
  # Chains) adds an entry here to scope its auth to only its own key,
  # denying it approval-key. See modules/secret-openbao-local/README.md.
  for_each = { for p in var.policies : p.name => p }

  name   = each.value.name
  policy = each.value.hcl
}

resource "local_file" "openbao_data_dir_keep" {
  # raft's bolt-based FSM does not auto-create its storage directory the
  # way the (now-deprecated) `file` backend did — verified live: `bao
  # server` fails with "failed to open bolt file: ... no such file or
  # directory" against a missing path. local_file's `filename` argument
  # auto-creates missing parent directories, so this placeholder is the
  # declarative way to guarantee the directory exists before pitchfork
  # ever starts `bao server` against it.
  filename        = "${var.openbao_data_path}/.gitkeep"
  content         = ""
  file_permission = "0644"
}

resource "local_file" "openbao_config" {
  filename        = var.openbao_config_path
  file_permission = "0644"

  content = templatefile("${path.module}/templates/openbao.hcl.tftpl", {
    data_path        = var.openbao_data_path
    node_id          = var.node_id
    listener_address = var.listener_address
    cluster_address  = var.cluster_address
  })
}
