# environments/local/flux/

The Flux config for the local OrbStack cluster. `environments/local/` owns
this directory (deployment selection + reconciliation policy); the manifests
it *points at* stay owned by their own concerns.

`environments/local/scripts/flux-bootstrap.sh` applies `flux-instance.yaml`
once. The FluxInstance then generates a `flux-system` GitRepository +
Kustomization that reconcile **this directory** from git — so every file here
is self-healed.

| file | |
|---|---|
| `flux-operator.lock` | pinned + cosign-verified digests (chart, operator image, distribution manifests). Bump procedure in its header. |
| `flux-instance.yaml` | the one `FluxInstance` |
| `flux-operator-helmrelease.yaml` | `OCIRepository` + `HelmRelease` — the operator self-manages after the bridge |
| `zot-sync.yaml` | Flux `Kustomization` → `environments/local/zot/` |
| `tests/crd-schemas/` | vendored CRD schemas for the `kubeconform-flux` hk step |

No `kustomization.yaml`: every `.yaml` here is a real manifest and there are
no test CRs to exclude, so Flux's recursive manifest discovery is safe. When
a directory Flux reconciles *does* mix manifests with tests/fixtures (the
`ci/` paths, T7c Increment 2), that directory gets an explicit
`kustomization.yaml` inventory.

Full walkthrough + lifecycle trace: `../README.md` § Flux.
