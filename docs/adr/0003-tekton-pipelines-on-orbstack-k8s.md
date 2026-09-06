# The pipeline engine is Tekton Pipelines + Chains on OrbStack's built-in k8s

The automated build → scan → SBOM path runs as a real Tekton Pipeline on
`orb start k8s` (OrbStack's single-command dev cluster), not `cluster-k0sctl`.
Tekton Chains observes each TaskRun and attaches a signed SLSA provenance
referrer. The Pipeline is instantiated per consumer from reusable
`modules/task-*` + `modules/pipeline-*` (architecture doc § File layout).

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

Status: Phase 1 ships this without Tekton (GitHub Actions + GHCR). Tekton
(Phase 2) is deferred and re-scoped — see `TODOS.md`.
