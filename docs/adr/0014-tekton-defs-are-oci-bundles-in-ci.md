# Tekton Task/Pipeline definitions are digest-pinned OCI bundles in `ci/`, not versioned directories in `modules/`

The reusable Tekton Task and Pipeline definitions live in a new top-level
`ci/` concern (`ci/tasks/`, `ci/pipelines/`, `ci/runtime/`), not under
`modules/`. They are distributed as **OCI bundles**: `tkn bundle push` a
Task/Pipeline to the registry, and a `PipelineRun` references it through the
bundles resolver pinned by `@sha256:` digest — cosign-signable like any
other artifact. Version is the OCI digest; git tags may be added later for
human release marking only, never as the pin.

Why: `modules/` is defined as *"reusable, versioned, URL-consumed OpenTofu
modules only"*, pinned by `source = "github.com/…//modules/<name>?ref=<sha>"`
(a git-commit hash). A Tekton Task is not OpenTofu — it is a build input to
an OCI artifact, the same category as `deploy/frontend/Dockerfile` or
`attestation/verdict-approved.cue`. The earlier "resolved exception" that
placed `modules/task-*` / `modules/pipeline-*` as Tekton YAML with the
[tektoncd/catalog](https://github.com/tektoncd/catalog) `<name>/<version>/`
convention put a second distribution model (path-encoded versions) inside a
folder whose whole contract is git-SHA-pinned OpenTofu. Path-encoded
versions also contradict this repo's own thesis
([ADR 0001](0001-digest-is-the-trust-boundary.md)) — the pin should be a
content digest, and Tekton bundles already are exactly that.

Considered and rejected:

- **Keep in `modules/`, drop the version directory** — smaller doc change,
  but still two distribution models (git-SHA vs OCI-bundle-digest) in one
  folder and still stretches "modules = OpenTofu".
- **`deploy/frontend/` only, promote when a second consumer appears** —
  YAGNI-correct for one consumer, but the design's stated goal is reusable,
  parameterised defs consumable by any future app and by a future
  `environments/production/`; per-consumer-only under-delivers that.

Consequence: `ci/` is consumer-agnostic — it never names `cv_frontend`. The
per-consumer instantiation (the `PipelineRun` binding one consumer's params
+ the pinned bundle digests) lives in `deploy/<consumer>/`, mirroring the
repo's reusable-defs / per-consumer-instantiation split. The Tekton
*controller* install and `zot` are vendored upstreams, not our reusable
code — they are `environments/*` concerns (a Flux `OCIRepository` /
`Kustomization`), not `ci/` and not `modules/`.

Status: accepted. Supersedes the CLAUDE.md "Module Structure & Naming"
resolved exception. Implemented across T7 (`TODOS.md`).
