# Local-environment composition — applies this repo's own modules as a
# working reference/test harness (CLAUDE.md § Repo Role). Currently just
# the local OpenBao/Transit signing backend the digest-as-source-of-truth
# pipeline's approval gate uses; vm-orbstack/cluster-k0sctl/secret-openbao
# join environments/production/ once those modules are built out.

locals {
  # The local OpenBao is ONE daemon per developer machine, not one per git
  # worktree/checkout (ADR 0010). Its rendered config, raft store and
  # snapshots therefore live in the XDG state dir, not under this worktree.
  # `bootstrap-openbao.sh` keeps tofu state next to them
  # (`tofu apply -state=<state_dir>/tofu.tfstate`), so any worktree's
  # bootstrap operates on the same instance.
  #
  # var.openbao_state_dir is a test seam (bats). Unset -> ~/.local/state/
  # toolbox/openbao (the XDG default; a non-default $XDG_STATE_HOME is not
  # honoured -- Terraform cannot read arbitrary env vars).
  openbao_state_dir = coalesce(var.openbao_state_dir, pathexpand("~/.local/state/toolbox/openbao"))
}

module "secret_openbao_local" {
  source = "../../modules/secret-openbao-local" # environments/local/ -> environments/ -> repo root -> modules/

  transit_keys = [
    { name = "approval-key", type = "ecdsa-p256" },
  ]
  openbao_config_path   = "${local.openbao_state_dir}/openbao.hcl"
  openbao_data_path     = "${local.openbao_state_dir}/data"
  openbao_snapshot_path = "${local.openbao_state_dir}/snapshots"
  listener_address      = var.openbao_listener_address

  # Auto-unseal via a static seal key (ADR 0010/0011). The id is a stable
  # label; the key itself is a 0600 file ($state_dir/seal.key) that
  # openbao.hcl reads via file://, written by bootstrap-openbao.sh.
  static_seal_key_id = "toolbox-local"
}
