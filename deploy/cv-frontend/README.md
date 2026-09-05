# deploy/cv-frontend

## Abstract

Per-consumer instantiation for the digest-as-source-of-truth pipeline's
`cv_frontend` consumer (CLAUDE.md § Module Structure & Naming's Tekton
exception: PipelineRun binding + consumer-specific scripts/tests live
here). Currently empty — T4 (GitHub Actions workflow) and T5
(`approve.sh`/`mise run consume`) land here next.

## Where OpenBao/Transit went

T3's OpenBao Transit engine + `approval-key` is **not** owned by this
directory. It lives in `environments/local/` (`modules/
secret-openbao-local` + `environments/local/main.tf`; `pitchfork.toml`
itself stays at repo root for daemon discoverability) because it's shared
infra, not a cv-frontend-specific concern — T8 (Phase 3) adds a second
Transit key (`chains-provenance-key`) to the same instance for a
repo-wide concern (Tekton Chains provenance), not another per-consumer
copy. See `environments/local/README.md` for the OpenBao bootstrap steps.

When T5 lands, `approve.sh` here signs via `openbao://approval-key` —
that key name, not a path into this directory.
