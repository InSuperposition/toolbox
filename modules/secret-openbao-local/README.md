# secret-openbao-local

## Abstract

Provisions an OpenBao Transit secrets engine and an arbitrary set of
Transit signing keys, plus the rendered `openbao.hcl` server config for a
**local, single-node, pitchfork-supervised dev OpenBao process**. Not a
network service, not HA, not the production secret store.

## Goals

- One Transit key per `transit_keys` entry, every key non-exportable and
  undeletable (see `tests/keys.tftest.hcl` — this is a tested invariant,
  not just a convention).
- A ready-to-run `openbao.hcl` (raft storage — not the deprecated `file`
  backend) at the path the caller chooses, for a pitchfork daemon to point
  `bao server -config=<path>` at.

## Constraints

- Loopback-only, TLS disabled — this module is scoped exactly as
  `pitchfork` is scoped in this repo: local dev daemon supervision (see
  CLAUDE.md § Tool Boundaries), not production infra.
- Key material never leaves OpenBao. The module enforces this in code
  (`exportable = false`), not just in a comment.

## Why this is a separate module from `modules/secret-openbao`

`modules/secret-openbao` is the deferred **production** module — OpenBao
running as real infra on `cluster-k0sctl`'s cluster, once that exists.
This module is the opposite lifecycle: a disposable, single-node, local
process a developer's machine supervises via `pitchfork`, used today by
the digest-as-source-of-truth pipeline's approval gate
(`docs/designs/digest-as-source-of-truth.md`). Sharing one module between
those two would couple a throwaway dev daemon's config surface to a
production secret store's — the naming keeps that distinction visible
instead of papering over it with one generically-named module trying to
serve both.

## Inputs / Outputs

See `variables.tf` / `outputs.tf`. The caller (currently the repo's root
composition) owns:

- Naming which keys exist (`transit_keys`) — a new consumer adds an entry
  here, it doesn't provision a second OpenBao instance.
- Where the rendered config lands (`openbao_config_path`) and what the
  supervising `pitchfork.toml`'s daemon command points at.

## Usage

```hcl
module "secret_openbao_local" {
  source = "./modules/secret-openbao-local"

  transit_keys = [
    { name = "approval-key", type = "ecdsa-p256" },
  ]
  openbao_config_path = "openbao/openbao.hcl"
}
```

Bootstrap (init/unseal) is a one-time, human-driven, out-of-band step —
documented at the repo root, not here, since it's a property of the
running OpenBao process, not of this module's `.tf` files.
