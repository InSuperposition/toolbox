# The pipeline engine is Tekton Pipelines + Chains on OrbStack's built-in k8s

The automated build → scan → SBOM path runs as a real Tekton Pipeline on
`orb start k8s` (OrbStack's single-command dev cluster), not `cluster-k0sctl`.
Tekton Chains observes each TaskRun and attaches a signed SLSA provenance
referrer. The Pipeline is instantiated per consumer from reusable Task /
Pipeline definitions — since superseded on *placement*: those defs live in
the `ci/` concern as digest-pinned OCI bundles, not `modules/task-*` /
`modules/pipeline-*` ([ADR 0014](0014-tekton-defs-are-oci-bundles-in-ci.md)).
The engine choice below stands.

Considered and rejected:

- **A — meta-only** (pin `mise.toml`, add the hk gate, defer the pipeline):
  the honest minimal fallback, but no live digest-vs-tag demo to show a
  reviewer. Kept as the fallback if Tekton setup stalls.
- **B — ad-hoc local/CI script** (same referrer mechanism, hand-run):
  doesn't match `tekton-cli`'s already-stated intent; "running the CLI
  locally is not very DevOps".
- **C — stand up Kyverno admission enforcement now**: XL, couples three
  independently-deferred concerns (Tekton, `cluster-k0sctl`, Kyverno) and
  contradicts the "no production cluster in this wedge" premise. Belongs
  after the pipeline is proven, not instead of it.

Status: accepted. Phase 1 shipped (GitHub Actions + GHCR). Phase 2 — the
Tekton Pipeline on OrbStack k8s — shipped: the build/scan/gate pipeline
(`ci/`, T7b1–b3) reconciled by Flux (T7c Increment 2). Tekton Chains
provenance is **T8**, still blocked on the in-cluster OpenBao move
(`TODOS.md` — the loopback listener cannot serve an in-cluster Chains pod).
