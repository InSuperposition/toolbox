# deploy/frontend

## Abstract

Per-consumer instantiation for the digest-as-source-of-truth pipeline's
`cv_frontend` consumer (CLAUDE.md § Module Structure & Naming's Tekton
exception: PipelineRun binding + consumer-specific scripts/tests live here;
directory named `frontend`, not `cv-frontend` — it holds whatever frontend
app is the pipeline's consumer, not tied to the `cv_` name forever).

This concern **owns** the image build (`Dockerfile`) and the in-cluster
publish step (`scripts/frontend-publish.sh`). It **may depend on** the
`attestation/` verify seam (through an env seam only — never a source/path
across the boundary) and `tests/lib`. The signing/verifying logic itself is
**not** here — it moved to [`attestation/`](../../attestation/README.md)
(ADR 0013), reusable by any consumer.

- **T4** (GitHub Actions build/scan/SBOM) — built, CI-green
  (`.github/workflows/build-cv-frontend.yml`); **retired** once T7c's
  in-cluster build (T7b3, below) proved stable end to end (`TODOS.md` T7,
  R4).
- **T5** (approve) — the seam is `attestation/scripts/attestation-sign.sh`
  / `attestation-verify.sh`. `mise run attestation:sign` /
  `attestation:verify`. See `attestation/README.md`.
- ~~**T5b** (verify + local deploy)~~ — the ADR-0009 pitchfork demo this
  covered is retired ([ADR 0023](../../docs/adr/0023-retire-adr-0009-pitchfork-demo.md)).
  The in-cluster path's own verify + consume gate is `frontend:publish`,
  T7b3 below.
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
   `gate` task**, the `buildkitd-mirror` ConfigMap in `ns ci`, zot answering
   HTTPS on `zot.zot.svc.cluster.local:5000` (T7c R1b-ii-c; needs `mise run
   local:zot:trust` for the host to trust it), and (idempotently, via
   `mise run frontend:seed`) the Dockerfile's base images in zot. Each
   missing prerequisite names its fix and exits 3.
2. Renders `pipelinerun.cue` with `cue export -t rev=<sha> -t defsRev=<toolbox-ref>`
   — a missing or non-hex SHA fails the render closed. `TOOLBOX_DEFS_REF`
   overrides the toolbox ref (default: `HEAD`); a Dockerfile that differs
   from that ref is a warning (the pipeline clones the ref, not your tree).
3. `kubectl create`s the PipelineRun (namespaced `ci`, 15m server-side
   timeout), streams `tkn` logs, and polls `.status.conditions[Succeeded]`
   until it leaves `Unknown` (client bound ~16m).
4. **Succeeded** → read the PipelineRun's own `IMAGE_DIGEST` result — the
   digest `build` captured at push time, never a fresh `oras resolve` of
   the mutable tag (Run-scoped build digest identity, TODOS.md; rejected
   unless a canonical `sha256:<64hex>` — exit 5), print this run's
   `vnd.trivy.report+json` referrer digest for the operator to eyeball,
   delete the run, and print the exact next line:
   `mise run attestation:sign -- zot.zot.svc.cluster.local:5000/cv-frontend@<digest>`.
5. **Failed** → the run + pods are kept. If the `gate` step is what failed,
   its terminated exitCode classifies the message: `2` → the loud
   "CRITICAL found, signing is a deliberate override" box; `1` → "gate
   ERRORED, not a vulnerability verdict"; otherwise a task failed before
   the gate ran.

The manifest digest is resolved once, here, by the operator — never a
Tekton result (ADR 0001). `pipelinerun.cue` is the single source of the
registry hostname: `zot.zot.svc.cluster.local:5000/cv-frontend` for both
the in-cluster pipeline and every host-side tool (T7c R1b-ii-c dropped
zot's NodePort — OrbStack routes the host into the cluster network
directly, so there's no separate loopback form anymore).

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
| `pipelinerun.cue` | the per-consumer `PipelineRun` binding (plain CUE, T7b3) — cv_frontend's registry facts, rendered by `frontend-build.sh` |
| `scripts/frontend-build.sh` | `mise run frontend:build` — in-cluster build/scan/gate (T7b3) |
| `scripts/frontend-publish.sh` | `mise run frontend:publish` — verify → render the Timoni module → `flux push` (Plan B M3, ADR 0019/0021) |
| `scripts/lib/frontend.sh` | shared by both: `frontend_attestation_verify` (the `TOOLBOX_ATTESTATION_VERIFY` seam) + `frontend-build.sh`'s in-cluster-build helpers |
| `scripts/tests/{frontend-build,frontend-publish,dockerfile-pin,timoni-vet}.bats`, `scripts/tests/helper.bash` | the test matrix — `frontend-build.bats` fakes the cluster/registry via a `PATH` shim, `frontend-publish.bats` stubs the verify seam |

## Known app issue

`cv_frontend` currently crashes at runtime with a Remix v3
`IMPORT_OUTSIDE_FILE_MAP` error (a different repo's bug, not this
pipeline's). The in-cluster Deployment's container probes are lenient
because of this (`environments/local/flux/frontend.yaml`); the
`frontend-delivery` chainsaw test asserts DELIVERY (the approved image
pulled and the container started), not app health.

## Where OpenBao/Transit and the sign/verify seam went

The OpenBao Transit engine + `approval-key` lives in `environments/local/`
(ADR 0012). The sign/verify/preflight seam + `verdict-approved.cue` +
`cosign-approval.pub` live in `attestation/` (ADR 0013) — consumer-agnostic,
so a second consumer never has to reach across into this directory.
`attestation-sign.sh` signs via `openbao://approval-key` — that key name,
not a path into any consumer directory.

