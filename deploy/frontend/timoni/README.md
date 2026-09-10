# cv_frontend — Timoni module

The Kubernetes manifests for the `cv_frontend` demo app, authored as a
[Timoni](https://timoni.sh) module (CUE). This is the **first real Timoni
module** in the repo (ADR 0019); `deploy/frontend/pipelinerun.cue` stays
plain CUE (a fire-and-forget PipelineRun does not earn a module — ADR 0014,
T7b3 plan D1).

## What it renders

`timoni build cv-frontend ./deploy/frontend/timoni` → a `ServiceAccount`, a
`Service`, and a `Deployment`. No ConfigMap (the app carries its own config),
no test Job (the k8s path is delivery-only — see below).

## Why Timoni here and not plain CUE

`pipelinerun.cue` is one self-contained file with no `cue.mod`. This module
is not, and the difference is the point:

- **A typed, schema-checked `#Config`** (`templates/config.cue`) is one
  contract across all three objects. `timoni mod vet` validates both the
  config *and* the rendered resources against the vendored Kubernetes CUE
  schemas (`cue.mod/gen`) — so a bad `apiVersion`, a wrong field type, or a
  tag-only image reference fails locally, before anything reaches a cluster.
  This replaces a second `kubeconform` pass (CLAUDE.md § Testing Strategy —
  one validator per concern).
- **The module is published as its own OCI artifact**, digest-pinned and
  independently versioned (M3): `timoni build` → `flux push artifact` → a
  Flux `OCIRepository`. A consumer pulls a specific digest, not an inline
  blob.
- **`timoni build` is reproducible** — same inputs, same bytes — which is
  what makes the manifest-artifact digest (`deploy/frontend/timoni.lock`) a
  meaningful pin.

## The image-digest constraint (load-bearing)

`#Config.image.digest` must match `^sha256:[0-9a-f]{64}$`. This mirrors
`attestation/scripts/lib/attestation.sh`'s `attestation_is_digest_ref`: a
tag is mutable, which is the whole point of the approval pipeline, so a
tag-only reference is rejected by `timoni mod vet` — not at reconcile time.
`tests/invalid-image-digest.cue` is the negative fixture proving it
(`deploy/frontend/scripts/tests/timoni-vet.bats`).

The real digest comes from `deploy/frontend/current-image.txt` (the approved
image, ADR 0009) at publish time; `images.cue` carries a valid-format
placeholder so `timoni mod vet` resolves with defaults.

## Delivery-only

The k8s Deployment is the Timoni/Flux *delivery* exercise. It does **not**
carry the launch-time approval re-verify that `frontend-serve.sh` does for
the pitchfork path (ADR 0009, retained) — in-cluster admission-time approval
enforcement is Kyverno's `ImageValidatingPolicy` (chunk K1). And
`cv_frontend` has an unresolved Remix v3 boot crash
(`deploy/frontend/README.md`), so the container probes are lenient and
`chainsaw-frontend` asserts "container started + correct image digest +
admitted", not "Available / HTTP 200".

## Vendored schemas

`cue.mod/gen` (Kubernetes APIs) and `cue.mod/pkg` (`timoni.sh/core`) are
committed — the upstream convention (`stefanprodan/timoni`'s own example
modules do the same) keeps `mise run check` and CI offline and hermetic,
consistent with the repo's vendored CRD schemas elsewhere. Regenerate with
`timoni mod vendor k8s`. `.gitattributes` marks them `linguist-generated`.

## Commands

| | |
|---|---|
| `mise run frontend:vet` | `timoni mod vet` — the schema gate (also the `timoni` hk step) |
| `timoni build cv-frontend ./deploy/frontend/timoni --values <f>` | render to YAML |
| `timoni mod vendor k8s` | refresh `cue.mod/gen` on a Kubernetes-schema bump |
