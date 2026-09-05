# deploy/frontend

## Abstract

Per-consumer instantiation for the digest-as-source-of-truth pipeline's
`cv_frontend` consumer (CLAUDE.md § Module Structure & Naming's Tekton
exception: PipelineRun binding + consumer-specific scripts/tests live
here; directory named `frontend`, not `cv-frontend` — this holds
whatever frontend app is the pipeline's consumer, not tied to the `cv_`
name forever). T4 (GitHub Actions workflow) is built
(`.github/workflows/build-cv-frontend.yml`). T5 (`approve.sh`/`mise run
consume`) and T5b (local pitchfork-supervised deploy, see below) land
here next.

## Where OpenBao/Transit went

T3's OpenBao Transit engine + `approval-key` is **not** owned by this
directory. It lives in `environments/local/` (`modules/
secret-openbao-local` + `environments/local/main.tf`; `pitchfork.toml`
itself stays at repo root for daemon discoverability) because it's shared
infra, not a frontend-specific concern — T8 (Phase 3) adds a second
Transit key (`chains-provenance-key`) to the same instance for a
repo-wide concern (Tekton Chains provenance), not another per-consumer
copy. See `environments/local/README.md` for the OpenBao bootstrap steps.

When T5 lands, `approve.sh` here signs via `openbao://approval-key` —
that key name, not a path into this directory.

## Local deploy (T5b, not yet built)

The approved digest runs as a standalone `pitchfork`-supervised Docker
container on this dev Mac — not a Kubernetes Deployment. `pitchfork.toml`
(repo root) gets a `[daemons.frontend]` entry pointing at `run.sh` here;
`run.sh` reads the currently-approved image reference from
`current-image.txt` (git-ignored, written atomically by `mise run
consume`), re-verifies its cosign approval via `scripts/
verify-approval.sh` (shared with `mise run consume` itself), then
`docker run --rm --platform linux/amd64 -p 44100:44100 <image>` in the
foreground — pitchfork is the sole process supervisor, no
`--restart=always` competing with it.

This deliberately reopened an earlier "locked" design decision (a
`cv-frontend` k8s namespace + `kubectl apply` on OrbStack's cluster) —
see `docs/designs/digest-as-source-of-truth.md`'s Approach D for the full
reasoning. `orb start k8s` still exists and still hosts Tekton
Pipelines/Chains (Phase 2+, T7/T8) — that dependency is unaffected; only
where the *app itself* runs changed.

T5b proves the pipeline mechanism (right image pulled, container starts,
HTTP readiness checked and its real result reported truthfully) — not
`cv_frontend`'s own correctness. `cv_frontend` currently crashes at
runtime with a Remix v3 `IMPORT_OUTSIDE_FILE_MAP` error (found during
T4a's dry run, a different repo's bug) — T5b's acceptance criteria
account for this explicitly, they don't block on it being fixed.
