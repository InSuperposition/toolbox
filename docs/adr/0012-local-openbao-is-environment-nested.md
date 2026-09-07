# The local-OpenBao tofu unit lives under `environments/local/`, not `modules/`

The local dev OpenBao tofu unit moves to `environments/local/openbao/`
(consumed by `environments/local/main.tf` as `source = "./openbao"`), and
its orchestration scripts (`openbao-bootstrap.sh` / `openbao-reset.sh` /
`openbao-snapshot.sh`) move from the repo-root `scripts/` to
`environments/local/scripts/`. `modules/` is reserved for reusable,
versioned, URL-consumed OpenTofu modules and holds only a README stating
that rule.

Why (this deliberately breaks the `secret-openbao` / `secret-openbao-local`
sibling symmetry described in earlier CLAUDE.md text): the local unit has
exactly one consumer — `environments/local/` — and no version pin, no
downstream repo, and a disposable lifecycle. Keeping it in `modules/`
alongside a genuinely reusable production module implied a parity that does
not exist and left the concern spread across three top-level directories
(`modules/`, `environments/local/`, root `scripts/`). The environment owns
bringing its own units up, so the scripts that run `tofu apply` / manage
the daemon belong with the environment, not with the unit. `modules/` stays
empty and honest until a real reusable module (the deferred production
`secret-openbao`) is built.

The tofu module label `module "secret_openbao_local"` is kept across the
move (only `source` changes, `../../modules/secret-openbao-local` →
`./openbao`) so no state address churns and the Phase 2 verification is an
in-place upgrade, not a destroy-and-recreate of the Transit key.

Status: accepted. Part of the repo-structure restructure
(`docs/designs/repo-structure.md`).
