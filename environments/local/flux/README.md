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
| `cert-manager.lock` | — (data; the digest pin + the authoring-time `cosign verify --key` record for the cert-manager chart, T7c Increment 4a) |
| `flux-instance.yaml` | **the bridge only** — excluded from `kustomization.yaml` (it is the acyclic anchor; self-healing it would revert a `spec.sync.ref` override and make the reconciler's own config a product of the reconciler) |
| `flux-operator-helmrelease.yaml` | Flux (helm-controller adopts the bridge's release, then owns upgrades) |
| `zot-sync.yaml` | Flux (kustomize-controller) |
| `ci-runtime.yaml` | Flux (kustomize-controller) — Kustomization `ci-runtime` → `./ci/runtime` (the `ci` namespace + `buildkitd-mirror` CM); CRD + Tekton-Deployment health checks, `deletionPolicy: Orphan` |
| `ci-defs.yaml` | Flux (kustomize-controller) — Kustomizations `ci-tasks` + `ci-pipelines` → `./ci/tasks` + `./ci/pipelines` into ns `ci`, `dependsOn: [ci-runtime]` (`ci-pipelines` also `[ci-tasks]`) |
| `cert-manager-helmrelease.yaml` | Flux (helm-controller) — OCIRepository (digest pin, no `verify` — cert-manager signs with a static key, cert-manager.lock) + HelmRelease into ns `cert-manager` (`crds.enabled/keep`, all 4 images digest-pinned). T7c Increment 4a. |
| `cert-manager-pki.yaml` | Flux (kustomize-controller) — a `Kustomization` CR (`cert-manager-pki`) pointing at `../cert-manager/`. Separate from flux-system: the Issuer CRs are custom kinds and a whole-Kustomization dry-run fails on a missing CRD, which would deadlock flux-system against the cert-manager HelmRelease that installs those CRDs. `retryInterval: 30s` rides out the transient "no matches for kind" until the CRDs land; `healthChecks` on the cert-manager Deployments. |
| `kustomization.yaml` | — (the explicit inventory for the generated `flux-system` Kustomization) |
| `tests/crd-schemas/` | — (vendored Flux + flux-operator v1/v2 schemas for the `kubeconform-flux` hk step; cert-manager's live under `../cert-manager/tests/crd-schemas/`) |

The `kustomization.yaml` here is explicit precisely to exclude
`flux-instance.yaml`. Directories Flux reconciles that mix manifests with
tests/fixtures (the `ci/runtime`, `ci/tasks`, `ci/pipelines` paths — which
sit beside `ci/tests/**`) each carry their own explicit
`kustomization.yaml` inventory for the same recursive-walk reason; those
inventories are owned by `ci/`, the Flux `Kustomization` CRs that point at
them (`ci-runtime.yaml`, `ci-defs.yaml`) are owned here.

Full walkthrough + lifecycle trace: `../README.md` § Flux.
