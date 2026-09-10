# In-cluster Kubernetes objects: render → reconcile → enforce → provision (and no tofu `kubernetes_*`)

The tools that touch in-cluster Kubernetes objects are **pipeline stages, not
rivals** — a given object has exactly one owner at exactly one stage:

| Stage | Tool | Job |
|---|---|---|
| **Render** | Timoni / CUE | produce the manifests (`deploy/frontend/timoni/`, `deploy/frontend/pipelinerun.cue`) |
| **Reconcile** | Flux | apply and keep them applied — including the Crossplane install, if one ever exists |
| **Enforce** | Kyverno | deny at admission what should not exist (`ImageValidatingPolicy`, chunk K1) — never mutate; an invisible admission rewrite is worse for review than rendered YAML |
| **Provision** | Crossplane | create the backing infra a consumer *declares* it needs (bucket / DB / queue / DNS as a CR) — **only if ever activated** |

Flux and Timoni **compose** — one reconciles what the other renders — they
are not alternatives to each other. Kyverno is on a different axis
(enforcement, not authoring) and never competes with the authoring tools.

**Crossplane's activation trigger** is a concrete platform-API / lifecycle
requirement — a consumer declaring backing infra it does not own — recorded
as `TODOS.md` T-X1. It is **not** a directory count: a second
`deploy/<consumer>/` shows duplication, which a shared kustomize base or Flux
plain-YAML handles. This matches Crossplane's structural place — it runs
inside a cluster it cannot create and consumes credentials from a secret
store it cannot provision (the ADR-0015 dependency inversion). Wrapping a
substrate module in `crossplane-contrib/provider-terraform` re-creates that
inversion under a drift-driven auto-apply and is **banned**.

**The per-consumer namespace bundle** — a `Namespace`, PSA labels, a
default-deny `NetworkPolicy` + explicit allows, a `ResourceQuota`, scoped
RBAC — is authored as **Flux plain-YAML** in `environments/local/`
(the `ci` namespace, `ci/runtime/namespace.yaml`, is the pattern today).
It stays plain-YAML indefinitely unless the Crossplane trigger fires. There
is no `XConsumerEnvelope` XRD and no forward-dated "Crossplane wins" clause.

**OpenTofu `kubernetes_*` / `kubernetes_manifest` resources are banned** —
zero exist today, and the `no-kubernetes-tf` `hk` step (a `git grep` over
`*.tf` — ast-grep ships no HCL grammar) keeps it that way. OpenTofu owns the
substrate unconditionally (VM, k0s, a future `modules/secret-openbao`) and
never reaches into the cluster's own object graph.

Status: accepted. **Amends [ADR 0015](0015-flux-precedes-in-cluster-openbao-gitrepository-plain-yaml.md)**
— Crossplane now has a defined boundary and a named activation trigger
(T-X1); it is not claimed to have a consumer (it has none) and it replaces
OpenTofu nowhere. Does not touch
[ADR 0003](0003-tekton-pipelines-on-orbstack-k8s.md),
[ADR 0014](0014-tekton-defs-are-oci-bundles-in-ci.md), or
[ADR 0016](0016-local-openbao-in-cluster-statefulset.md).
