# deploy/frontend

## Abstract

Per-consumer instantiation for the digest-as-source-of-truth pipeline's
`cv_frontend` consumer (CLAUDE.md § Module Structure & Naming's Tekton
exception: PipelineRun binding + consumer-specific scripts/tests live here;
directory named `frontend`, not `cv-frontend` — it holds whatever frontend
app is the pipeline's consumer, not tied to the `cv_` name forever).

This concern **owns** the image build (`Dockerfile`) and the local demo
deploy (`scripts/frontend-deploy.sh`, `scripts/frontend-serve.sh`). It
**may depend on** the `attestation/` verify seam (through an env seam only —
never a source/path across the boundary) and `tests/lib`. The
signing/verifying logic itself is **not** here — it moved to
[`attestation/`](../../attestation/README.md) (ADR 0013), reusable by any
consumer.

- **T4** (GitHub Actions build/scan/SBOM) — built, CI-green
  (`.github/workflows/build-cv-frontend.yml`).
- **T5** (approve) — the seam is `attestation/scripts/attestation-sign.sh`
  / `attestation-verify.sh`. `mise run attestation:sign` /
  `attestation:verify`. See `attestation/README.md`.
- **T5b** (verify + local deploy) — `scripts/frontend-deploy.sh`,
  `scripts/frontend-serve.sh`, `pitchfork.toml` `[daemons.frontend]`. See
  "Consume + deploy" below.
- **T7b** (in-cluster build) — the reusable Tekton graph is `ci/`. Before a
  local run, `mise run frontend:seed` mirrors this `Dockerfile`'s
  digest-pinned base images into the in-cluster zot (the OrbStack
  IPv6-egress defect — `ci/README.md` § Deterministic builds on OrbStack,
  `TODOS.md` T7b1-followup). The per-consumer `PipelineRun` is
  `pipelinerun.cue` here (**plain CUE**, not a Timoni module), rendered by
  `scripts/frontend-build.sh` (`mise run frontend:build`, T7b3).

## Build (T7b3)

```
mise run frontend:build -- <cv_frontend-sha>
```

`scripts/frontend-build.sh` is the operator entrypoint for the in-cluster
build/scan/gate pipeline:

1. Preflights the cluster prerequisites — a reachable `${TOOLBOX_KUBE_CONTEXT:-orbstack}`
   context, the `build-scan-approve` Pipeline present **and carrying the
   `gate` task**, the `buildkitd-mirror` ConfigMap in `ns ci`, zot on
   `localhost:30500`, and (idempotently, via `mise run frontend:seed`) the
   Dockerfile's base images in zot. Each missing prerequisite names its fix
   and exits 3.
2. Renders `pipelinerun.cue` with `cue export -t rev=<sha> -t defsRev=<toolbox-ref>`
   — a missing or non-hex SHA fails the render closed. `TOOLBOX_DEFS_REF`
   overrides the toolbox ref (default: `HEAD`); a Dockerfile that differs
   from that ref is a warning (the pipeline clones the ref, not your tree).
3. `kubectl create`s the PipelineRun (namespaced `ci`, 15m server-side
   timeout), streams `tkn` logs, and polls `.status.conditions[Succeeded]`
   until it leaves `Unknown` (client bound ~16m).
4. **Succeeded** → `oras resolve` the manifest digest (rejected unless a
   canonical `sha256:<64hex>` — exit 5), print this run's
   `vnd.trivy.report+json` referrer digest for the operator to eyeball,
   delete the run, and print the exact next line:
   `mise run attestation:sign -- localhost:30500/cv-frontend@<digest>`.
5. **Failed** → the run + pods are kept. If the `gate` step is what failed,
   its terminated exitCode classifies the message: `2` → the loud
   "CRITICAL found, signing is a deliberate override" box; `1` → "gate
   ERRORED, not a vulnerability verdict"; otherwise a task failed before
   the gate ran.

The manifest digest is resolved once, here, by the operator — never a
Tekton result (ADR 0001). `pipelinerun.cue` is the single source of both
registry hostnames: the pipeline pushes/scans over
`zot.zot.svc.cluster.local:5000/cv-frontend`, every host-side tool uses
`localhost:30500/cv-frontend`, the digest is the same.

## Consume + deploy (T5b)

The consumer of an approved image, here, is a local
`pitchfork`-supervised Docker container on the dev Mac — a demo/proof of
the pipeline mechanism, not where a real site lives
(`docs/adr/0009-demo-consumer-is-local-container-not-k8s.md`).

```
mise run frontend:deploy -- ghcr.io/insuperposition/cv-frontend@sha256:<digest> sha256:<attestation-digest>
```

`scripts/frontend-deploy.sh`:

1. Verifies the pinned approval attestation through the
   `TOOLBOX_ATTESTATION_VERIFY` seam (`lib/frontend.sh` — default is
   `attestation/scripts/attestation-verify.sh`, resolved through the
   checkout root). If it fails, **nothing changes** — the state file and
   the running container are left as they were, and it exits non-zero.
2. Atomically (temp + rename) records the full image reference and the
   attestation digest in `current-image.txt` (git-ignored, per-machine).
3. `pitchfork restart frontend`.
4. Polls the published host port and reports the **real** result — HTTP
   code if it comes up, a "did NOT come ready" message (exit 1) if it
   doesn't. `cv_frontend` has a known Remix v3 runtime crash, so this step
   failing for the real app is expected; T5b proves the pipeline, not the
   app.

`scripts/frontend-serve.sh` is the pitchfork `frontend` daemon's
entrypoint. `pitchfork.toml` points `run` at it and nothing else — a
deploy records into `current-image.txt`, it never rewrites pitchfork's
config. On every launch it re-reads `current-image.txt`, **re-verifies the
approval** (not just at deploy time, same seam), then runs the container in
the foreground with the traps that stop it cleanly on pitchfork's signal
(no orphan). Bounded retries with backoff on a *retryable* verify failure
(`attestation-verify.sh` exit 3), then a visible stopped state; a
*terminal* failure (bad signature / verdict rejected — exit 1) stops at
once. Works on a cold, non-interactive start — the image and its referrers
are pulled anonymously, no inherited credentials.

Known gap, named not solved: launch-time verification does not stop an
**already-running** container whose image is rejected afterwards. That
needs a separate watch, deferred.

`mise run attestation:verify` runs just the check, no deploy.

## How the verify seam is reached

`lib/frontend.sh` holds the one allowed cross-concern edge: `deploy/frontend
▶ attestation`. It runs through `TOOLBOX_ATTESTATION_VERIFY` (the same shape
as `TOOLBOX_APPROVAL_PUBKEY` / `TOOLBOX_APPROVE_KEY`); the default resolves
`attestation/scripts/attestation-verify.sh` through the `mise.toml`
checkout-root marker, not a `../attestation` relative climb, so the
boundary lint stays honest. bats point the seam at a scratch copy.

`attestation-verify.sh` verifies against `attestation/cosign-approval.pub`,
exported once from `openbao://approval-key` at bootstrap. Losing the OpenBao
raft store stops *future* signing but does not invalidate any past
approval. Only `attestation-sign.sh` needs OpenBao up and unsealed
(`docs/adr/0005-consume-verifies-against-committed-pubkey.md`).

## Files

| File | Role |
|---|---|
| `Dockerfile`, `Dockerfile.dockerignore` | distroless Node image for `cv_frontend` (ADR 0007) — the one hand-authored Dockerfile carve-out |
| `scripts/frontend-deploy.sh` | `mise run frontend:deploy` — verify, record `current-image.txt`, restart the daemon, readiness-check |
| `scripts/frontend-serve.sh` | pitchfork `frontend` daemon entrypoint — re-verify + run the container in the foreground |
| `scripts/lib/frontend.sh` | `frontend_repo_root` + `frontend_attestation_verify` — the `TOOLBOX_ATTESTATION_VERIFY` seam |
| `current-image.txt` | git-ignored, per-machine — the image ref + attestation digest the daemon deploys |
| `scripts/tests/{frontend-deploy,frontend-serve}.bats`, `scripts/tests/helper.bash` | the test matrix — a local zot + a throwaway cosign key via the `TOOLBOX_APPROVE_KEY` seam; every scratch test exercises the **default** `TOOLBOX_ATTESTATION_VERIFY` seam (C4); `[docker]` cases also need docker |

## Where OpenBao/Transit and the sign/verify seam went

The OpenBao Transit engine + `approval-key` lives in `environments/local/`
(ADR 0012). The sign/verify/preflight seam + `verdict-approved.cue` +
`cosign-approval.pub` live in `attestation/` (ADR 0013) — consumer-agnostic,
so a second consumer never has to reach across into this directory.
`attestation-sign.sh` signs via `openbao://approval-key` — that key name,
not a path into any consumer directory.

## Why a local container, not a k8s Deployment

This reopened an earlier "locked" decision (a `cv-frontend` k8s namespace +
`kubectl apply` on OrbStack's cluster) — see
`docs/adr/0009-demo-consumer-is-local-container-not-k8s.md` for the full
reasoning. `orb start k8s` still exists and still hosts Tekton
Pipelines/Chains (Phase 2+) — that dependency is unaffected; only where the
*app itself* runs changed.

This proves the pipeline mechanism (right image pulled, container starts,
HTTP readiness checked and its real result reported truthfully) — not
`cv_frontend`'s own correctness. `cv_frontend` currently crashes at
runtime with a Remix v3 `IMPORT_OUTSIDE_FILE_MAP` error (a different repo's
bug); the readiness check reports that truthfully and `frontend-deploy.sh`
exits non-zero, but the image is still recorded and the daemon still
restarted — the mechanism worked.
