# The cv_frontend manifest publish is a host operator step, not a Tekton Task

Plan B M3 delivers `cv_frontend` in-cluster by rendering the Timoni module
(ADR 0019) against the approved image digest and pushing the rendered YAML
as an OCI artifact for Flux to reconcile. The earlier plan put render+publish
in a Tekton Task (`ci/tasks/timoni-publish.yaml`). We instead do it in a host
mise task, `mise run frontend:publish` (`deploy/frontend/scripts/frontend-publish.sh`):
verify the pinned approval attestation through the `TOOLBOX_ATTESTATION_VERIFY`
seam (nothing renders or pushes if it fails), then `timoni build` →
`flux push artifact --output json`. This matches how the rest of the seam
already works — `attestation:sign` and `frontend:deploy` are host operator
steps at the digest boundary, and `frontend-build.sh` explicitly notes "sign
and consume stay outside the pipeline" (ADR 0013). It also sidesteps two real
costs of the Task: `timoni` ships no container image (we would have to author
and digest-pin a second Dockerfile — a Scripts/Dockerfile-policy carve-out
expansion), and the module lives in this repo (a git-clone-toolbox workspace
step). The trade-off accepted: `frontend-publish.sh` is a script where the
declarative-first mandate prefers `command`+`args`, justified by its genuine
verify-gate conditional (Scripts Policy) and covered by
`frontend-publish.bats`. The *delivery* stays fully declarative — the Flux
`OCIRepository` + two `Kustomization` CRs in `environments/local/flux/frontend.yaml`.

## Consequences

- `timoni build` is reproducible, but `flux push` stamps a timestamp
  annotation, so `D_man` (the manifest-artifact digest) changes per publish.
  The operator copies the printed `D_man` into `deploy/frontend/timoni.lock`
  and `frontend.yaml` in the reviewed PR — the git pin is the reviewed
  artifact (ADR 0001), never auto-committed.
- If a webhook-driven or fully in-cluster publish is ever needed, this
  becomes a Tekton Task then (Pipelines-as-Code is already the researched
  trigger mechanism) — the split verify-then-publish shape carries over.
