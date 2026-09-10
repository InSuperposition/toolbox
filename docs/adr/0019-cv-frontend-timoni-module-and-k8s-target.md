# `cv_frontend` is a Timoni module delivered into the OrbStack cluster

`cv_frontend`'s Kubernetes manifests are authored as a Timoni module
(`deploy/frontend/timoni/`, CUE) and delivered into the local OrbStack
cluster: `timoni build` → `flux push artifact` → a Flux `OCIRepository` +
`Kustomization` (chunk M3). This is the first real Timoni module in the repo
— `deploy/frontend/pipelinerun.cue` stays plain CUE (a fire-and-forget
PipelineRun does not earn a module, [ADR 0014](0014-tekton-defs-are-oci-bundles-in-ci.md)).

Why Timoni and not plain CUE + `cue export` (the `pipelinerun.cue` shape):
the module carries a typed `#Config` that is one schema-checked contract
across the Deployment + Service + ServiceAccount, and `timoni mod vet`
validates both the config and the rendered resources against the vendored
Kubernetes CUE schemas — so it is the schema gate for the timoni path and a
second `kubeconform` pass is not run (CLAUDE.md § Testing Strategy, one
validator per concern). The module is published as its own digest-pinned,
independently-versioned OCI artifact rather than an inline blob, and
`timoni build` is reproducible, which is what makes the manifest-artifact
digest (`deploy/frontend/timoni.lock`) a meaningful pin. `#Config.image.digest`
is constrained to a full `sha256:` digest, mirroring
`attestation_is_digest_ref` — a tag-only reference fails `timoni mod vet`,
not reconcile.

The k8s Deployment is the Timoni/Flux **delivery** exercise. It does not
carry the launch-time approval re-verify `frontend-serve.sh` does for the
pitchfork path — in-cluster admission-time approval enforcement is Kyverno's
`ImageValidatingPolicy` (chunk K1, its own ADR when it lands). The
publish path still runs `attestation-verify.sh` on the image the module pins
([ADR 0002](0002-approval-record-not-digest-alone.md) /
[0005](0005-consume-verifies-against-committed-pubkey.md) /
[0006](0006-approval-selection-is-attestation-digest-pin.md)).

The vendored `cue.mod/{gen,pkg}` schema tree is committed (upstream Timoni
convention; keeps `mise run check` + CI offline, consistent with the repo's
other vendored schemas). `.gitattributes` marks it `linguist-generated`.

Status: accepted. **Amends
[ADR 0009](0009-demo-consumer-is-local-container-not-k8s.md)** — the demo app
now also runs as a Kubernetes Deployment, not only a pitchfork-supervised
container. ADR 0009's rationale (Tekton's k8s dependency is about the build
engine, not a requirement that the app live in-cluster) is narrowed, not
reversed: the pitchfork container is retained as the path with full
launch-time approval enforcement; the k8s Deployment is delivery-plus-admission.
Folds in the earlier "M2" decision (the k8s delivery target) — no separate
unnumbered ADR.
