# environments/local/flux/

The Flux config for the local OrbStack cluster. `environments/local/` owns
this directory (deployment selection + reconciliation policy); the manifests
it *points at* stay owned by their own concerns.

`environments/local/scripts/flux-bootstrap.sh` applies `flux-instance.yaml`
once. The FluxInstance then generates a `flux-system` GitRepository +
Kustomization that reconcile **this directory** from git.

| file | reconciled by |
|---|---|
| `flux-operator.lock` | — (data; the bridge + kubeconform read it) |
| `flux-instance.yaml` | **the bridge only** — excluded from `kustomization.yaml` (it is the acyclic anchor; self-healing it would revert a `spec.sync.ref` override and make the reconciler's own config a product of the reconciler) |
| `flux-operator-helmrelease.yaml` | Flux (helm-controller adopts the bridge's release, then owns upgrades) |
| `zot-sync.yaml` | Flux (kustomize-controller) |
| `kustomization.yaml` | — (the explicit inventory for the generated `flux-system` Kustomization) |
| `tests/crd-schemas/` | — (vendored schemas for the `kubeconform-flux` hk step) |

The `kustomization.yaml` here is explicit precisely to exclude
`flux-instance.yaml`. Directories Flux reconciles that mix manifests with
tests/fixtures (the `ci/` paths, T7c Increment 2) get an explicit inventory
for the recursive-walk reason instead.

Full walkthrough + lifecycle trace: `../README.md` § Flux.
