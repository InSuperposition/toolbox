# Root composition — applies this repo's own modules as a working
# reference/test harness (CLAUDE.md § Repo Role). Currently just the local
# OpenBao/Transit signing backend the digest-as-source-of-truth pipeline's
# approval gate uses; vm-orbstack/cluster-k0sctl/secret-openbao join this
# file once those modules are built out.

module "secret_openbao_local" {
  source = "./modules/secret-openbao-local"

  transit_keys = [
    { name = "approval-key", type = "ecdsa-p256" },
  ]
  openbao_config_path = "openbao/openbao.hcl"
}
