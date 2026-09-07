# environments/local/openbao — the local OpenBao tofu unit

## Abstract

Provisions an OpenBao Transit secrets engine and an arbitrary set of
Transit signing keys, plus the rendered `openbao.hcl` server config for a
**local, single-node, pitchfork-supervised dev OpenBao process**. Not a
network service, not HA, not the production secret store.

`environments/local/main.tf` consumes it as `module "secret_openbao_local"`
(`source = "./openbao"`). It is a **tofu unit owned by this environment**,
not a published module — one in-repo consumer, no version pin, disposable
lifecycle (ADR 0012). The module label is kept as `secret_openbao_local`
so the tofu state addresses did not churn when it moved out of `modules/`.

## Goals

- One Transit key per `transit_keys` entry, every key non-exportable and
  undeletable (see `tests/keys.tftest.hcl` — a tested invariant, not just a
  convention).
- A ready-to-run `openbao.hcl` (raft storage — not the deprecated `file`
  backend) at the path the caller chooses, for a pitchfork daemon to point
  `bao server -config=<path>` at.

## Constraints

- Loopback-only, TLS disabled — scoped exactly as `pitchfork` is scoped in
  this repo: local dev daemon supervision (CLAUDE.md § Tool Boundaries),
  not production infra.
- Key material never leaves OpenBao. Enforced in code (`exportable =
  false`), not just in a comment.

## Why this is not `modules/secret-openbao`

`modules/secret-openbao` is the deferred **production** module — OpenBao
running as real infra on `cluster-k0sctl`'s cluster, once that exists, and
published for downstream repos to pin. This unit is the opposite
lifecycle: a disposable single-node local process a developer's machine
supervises via `pitchfork`, used today by the digest-as-source-of-truth
pipeline's approval gate (`docs/designs/digest-as-source-of-truth.md`).
Sharing one module between the two would couple a throwaway dev daemon's
config surface to a production secret store's. ADR 0012 records the split.

## Inputs / Outputs

See `variables.tf` / `outputs.tf`. The caller (`environments/local/main.tf`)
owns:

- Naming which keys exist (`transit_keys`) — a new consumer adds an entry
  here, it doesn't provision a second OpenBao instance.
- Naming which access policies exist (`policies`, default empty) — e.g.
  T8 (Tekton Chains) scoping its auth to only its own Transit key. Policy
  HCL syntax isn't validated offline; see `tests/policies.tftest.hcl`'s
  header comment and `../scripts/tests/openbao-bootstrap.bats` for the
  live check.
- Where the rendered config lands (`openbao_config_path`) and what the
  supervising `pitchfork.toml` daemon command points at.

## Usage

```hcl
module "secret_openbao_local" {
  source = "./openbao"

  transit_keys = [
    { name = "approval-key", type = "ecdsa-p256" },
  ]
  openbao_config_path = "openbao/openbao.hcl"
}
```

Bootstrap (init/unseal) is a one-time, machine-driven step —
`environments/local/scripts/openbao-bootstrap.sh`, documented in
`../README.md`, not here, since it's a property of the running OpenBao
process, not of this unit's `.tf` files.
