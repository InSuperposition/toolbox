# T7c order: Flux precedes the in-cluster OpenBao move; Flux reconciles plain YAML from a `GitRepository`

Flux comes up before the in-cluster OpenBao move; that move is a dedicated
later unit (its own plan, its own blockers), and Crossplane is not sequenced
at all — it has no consumer. Flux reconciles this repo's hand-written plain
YAML from a `GitRepository`, each reconciled path carrying its own
`kustomization.yaml` inventory so the recursive kustomize walk never reaches a
directory's tests or fixtures; rendered or packaged artifacts (a Timoni
bundle, an `oras`-pushed def bundle) may use an `OCIRepository` later, running
side by side with the `GitRepository`.

Why: Flux *install* needs nothing from OpenBao — committed-pubkey cosign
verification and plain-YAML reconciliation have no online-secret dependency,
and the public repo syncs over anonymous HTTPS with no read credential. The
in-cluster OpenBao move is ~80% of the remaining work and almost entirely
imperative host-driven bootstrap (seal-key Secret chain, first `bao operator
init`, k8s-auth config, a key-preserving raft snapshot migration); front-loading
it would block the GitOps loop on the hardest piece. `GitRepository` + plain
YAML is Flux's documented default and is correct here indefinitely — the OCI
path is for the rendered/packaged artifact layer, not a migration target for
hand-written manifests.

Consequence: [ADR 0014](0014-tekton-defs-are-oci-bundles-in-ci.md)'s
definition ownership and the eventual Tekton-bundle distribution decision are
**unchanged** — the plain Flux `Kustomization` over `ci/tasks` + `ci/pipelines`
(T7c Increment 2) is the declarative interim that replaces the hand-`kubectl
apply`, and the OCI-bundle form stays the eventual target. The Tekton
*controller* install stays on the pinned checksum installer
(`environments/local/scripts/tekton-install.sh`, T7c Increment 0) — Flux
cannot install an absent Tekton, so it is a named external prerequisite for
the `ci-runtime` Flux `Kustomization`, not something Flux owns. There is no
"reserved for Timoni" prohibition on `OCIRepository`, and `timoni push` does
not feed Flux directly (the real flow is `timoni build` / `timoni bundle
build` → `flux push artifact` → `OCIRepository`).

Status: accepted. Increments 0/1a/1b/2 shipped (`TODOS.md`, T7c);
Increment 4+ (in-cluster OpenBao) is a separate plan. Does **not** supersede
ADR 0003 or ADR 0014.
