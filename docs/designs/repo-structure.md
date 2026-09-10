# Design: Repo Structure — Ownership Boundaries

## Abstract

`toolbox` has had no written file-placement rule. The symptoms: shell
scripts split across `scripts/` and `deploy/frontend/scripts/` with no
stated reason, `.bats` files under two conventions (one set not beside the
scripts it covers), the local-OpenBao concern spread over `modules/`,
`environments/local/`, and root `scripts/`, and a consumer-agnostic
sign/verify seam filed inside its first consumer (`deploy/frontend/`).

This design defines the rule every file obeys: **each top-level concern
has one owner and a declared list of the concerns it may depend on; a file
lives with the concern that owns it, not by how deep a directory nests.**
The allowed dependency edges are explicit and machine-checked in
`mise run check`.

## Goals

- One written rule — ownership plus allowed edges — that every future file
  obeys, checked by `mise run check`.
- Every `.bats` in a `tests/` directory beside the script it covers.
- A repo-level shared test lib; a per-concern runtime `lib/` only where
  real shared logic exists.
- The local-OpenBao concern coherent: the tofu unit in one place, its
  orchestration scripts in the environment that owns bringing it up.
- The attestation sign/verify seam in its own boundary, reusable by any
  consumer, never referencing a consumer.
- mise tasks namespaced `<environment>:<domain>:<verb>` / `<domain>:<verb>`.

## Constraints

- The rule is normative and the tree matches it (see Migration status
  below). The `ci/` concern (reusable Tekton defs, content-digest-pinned,
  [ADR 0014](../adr/0014-tekton-defs-are-oci-bundles-in-ci.md)) holds
  `tasks/{git-clone,buildkit-build,scan-attach}.yaml`, `pipelines/build-scan-approve.yaml`,
  `runtime/` (namespace + the interim `buildkitd-mirror` ConfigMap), and the
  `kubeconform` / `chainsaw` / `registry-seed` scripts (`TODOS.md` T7). The distribution mechanism (`tkn bundle` vs Flux `OCIRepository`) is
  a T7c-pre-plan call. Tekton defs are **not** `modules/*` entries.
- `mise run check` stayed green after every phase; it still gates every change.
- `git mv` and a logic change never land in the same commit — refactor,
  then change.
- `hk` stays the only git-hook gate; its config gains steps, is never
  bypassed.
- `deploy/frontend/Dockerfile` carve-out is unchanged
  ([ADR 0007](../adr/0007-distroless-dockerfile-not-buildpacks.md)).
- No external repo pins `modules/*` or `environments/*` today — the
  restructure is free to move directories; the module-extraction cost is
  paid later if a downstream consumer appears.

## The rule

1. Every top-level concern directory has **one owner** and a declared list
   of the concerns it **may depend on**.
2. A file is placed with the concern that **owns** it — not by "lowest
   containing directory". Containment breaks on the real cross-concern
   edges (a shared test lib, a verify seam consumed from two places).
3. Allowed dependency edges are explicit and machine-checked. A reference
   (path string, relative climb, `source`, exec) that crosses a boundary
   not on the allow-list fails `mise run check`.

"Concern" here is coarse — about five in this repo, not one per directory.
The owner is the directory itself; the allow-list is the set of other
concerns whose files it may name.

## The concerns and their allowed edges

```
                       tests/lib   (leaf — tests only; any concern may load it)
                           ▲
         ┌─────────────────┼──────────────────────┐
         │                 │                      │
   deploy/frontend ──────▶ attestation      environments/local
         │                                        │  owns openbao/  (source = ./openbao)
         │  frontend consumes the verify          │  owns its orchestration scripts
         │  seam — the one allowed edge           ▼
         └──────────────────────────────  environments/local/openbao   (tofu unit — leaf)

FORBIDDEN:
  attestation                     ─╳▶  deploy/*                a seam never names its consumers
  ci                              ─╳▶  deploy/*                a seam never names its consumers (ADR 0014)
  environments/local/openbao      ─╳▶  attestation, deploy/*, environments/local/scripts
  environments/local/scripts      ─╳▶  attestation, deploy/*   (calls the attestation:export-pubkey TASK,
                                                                never writes the pubkey file)
  tests/lib                       ─╳▶  any concern             scratch helpers take copy-paths as ARGS
  anything                        ─╳▶  modules/*               except a published-module `source` pin

Runtime-only edges (env vars / mise-task calls, not file paths — allowed, not "dependencies"):
  attestation/scripts/openbao-preflight.sh       ··▶  OpenBao daemon        via $VAULT_ADDR
  deploy/frontend/scripts/frontend-serve.sh      ··▶  attestation-verify    via $TOOLBOX_ATTESTATION_VERIFY
  environments/local/scripts/openbao-bootstrap.sh ··▶ `mise run attestation:export-pubkey`  (task call, not a file write)

Deployment-composition edge (a manifest-ref, not a shell path — select + target-namespace + order + reconciliation policy; ownership stays with the target):
  environments/local/  ──▶  ci/{runtime,tasks,pipelines}   Flux `Kustomization` CRs in environments/local/flux/ point at ci/ paths (T7c Increment 2)
```

**The 3-way split for the `ci/` reconcile (T7c Increment 2):** `ci/` owns
the reusable definitions **and their per-path `kustomization.yaml`
inventories** (`ci/runtime/kustomization.yaml`, `ci/tasks/kustomization.yaml`,
`ci/pipelines/kustomization.yaml` — each enumerating only real manifests so
Flux's recursive walk never reaches `ci/tests/**`). `environments/local/`
owns **deployment selection, target namespace, ordering and reconciliation
policy** — the Flux `Kustomization` CRs (`environments/local/flux/ci-runtime.yaml`,
`ci-defs.yaml`). **Flux** manages the resulting live resources. One source
owner per file, unchanged. Moving the Flux `Kustomization` CRs into `ci/`
would couple the reusable defs to local source names + deployment policy, so
they stay in `environments/local/flux/`.

| concern | owns | may depend on |
|---|---|---|
| `tests/` | repo-level shared test support (`lib/`, the coverage guard) | nothing — leaf; concern-agnostic (helpers take paths as args) |
| `attestation/` | the sign + verify + preflight seam, `verdict-approved.cue`, `cosign-approval.pub` | `tests/lib` |
| `deploy/frontend/` | one consumer of an approved image: build, deploy, serve | `attestation` (the verify seam, via env), `tests/lib` |
| `environments/local/` | one deployment target: the tofu composition, the orchestration scripts that bring its units up | its own `openbao/` unit, `tests/lib`; calls `attestation:export-pubkey` as a task |
| `environments/local/openbao/` | the local-OpenBao **tofu unit** only (host pitchfork daemon — retires at T7c Increment 4d) | `tests/lib` (for its `.tftest.hcl`) — leaf |
| `environments/local/openbao/` | the **in-cluster** local-OpenBao tofu unit (ADR 0016 — Phase A `helm_release` + Phase C `vault_*`) | `tests/lib` — leaf |
| `ci/` | reusable Tekton Task/Pipeline defs → digest-pinned OCI bundles; `ci/runtime/` namespace; each path's `kustomization.yaml` inventory; the bundle-push + taskrun scripts | `tests/lib`. **Never names a consumer** (like `attestation/`) — machine-checked (`rules/boundary-ci.yml`). `deploy/<consumer>/` consumes `ci/` bundles by digest via a pinned `PipelineRun`. Tekton **controller** + `zot` installs are `environments/local/`, not `ci/`; from T7c Increment 2 the Task/Pipeline **defs** are reconciled by Flux `Kustomization` CRs that live in `environments/local/flux/` (deployment policy is `environments/local/`'s, the defs + inventories stay `ci/`'s). |
| `modules/` | reusable, versioned, URL-consumed OpenTofu modules only | — (empty today; a README states the rule) |

## Naming

- **Script files:** `<domain>-<verb>.sh`, where `<domain>` is the **tool**
  (`openbao-bootstrap.sh`, `attestation-sign.sh`), never the directory
  name. This decouples file names from directory renames. The `.sh` stem
  matches `^[a-z]+(-[a-z]+)+$`.
- **Directories:** kebab-case.
- **Tests:** `<concern>/scripts/tests/*.bats`, beside the scripts. The tofu
  unit keeps `<unit>/tests/*.tftest.hcl`.
- **Shared test lib:** each `<concern>/scripts/tests/` has a `helper.bash`
  that walks up to the checkout root (the `mise.toml` marker — no fixed
  depth, no `BATS_LIB_PATH`, no `setup_suite.bash` discovery, no mise
  `[env]` coupling — F2) and sources the repo-level `tests/lib/*.bash`
  (`ports.bash` first — `registry.bash` needs `free_port`). A `.bats` file
  reaches the lib with the standard `load helper`. Anything concern-specific
  stays in that same `helper.bash`.
- **Parallel-safe suites:** a suite that binds a network port or names a
  container takes a fresh one per test — `free_port` for the OpenBao
  listener, `frontend_isolation` for the docker deploy (a free host port
  mapped to the fixed container port 44100, plus a unique container name).
  Teardown is scoped to the test's own daemon/container — never a
  machine-wide `pitchfork clean` or a fixed `docker rm`. Two `mise run
  check` in separate worktrees run without collision.
- **Runtime shared shell:** `<concern>/scripts/lib/<domain>.sh` — a single
  lowercase word (not `<verb>`-bearing); `.ls-lint.yml` relaxes the stem
  rule under `**/scripts/lib`. Self-contained, no repo-level runtime lib.
  The `SCRIPT_DIR` / `REPO_ROOT` idiom stays inline (standard bash, not
  domain logic).
- **Test support** lives under a `tests/` path; a production script never
  sources from a `tests/` path.

## mise task map

`<environment>:<domain>:<verb>` for environment-scoped work,
`<domain>:<verb>` otherwise. `check` / `fix` stay top-level. A task body
is a single inline command unless it has a loop, a conditional, error
classification, or a multi-step sequence with an invariant — only then
does it get a script.

```
BEFORE                    AFTER                          form
(ADR 0016)                local:openbao:bootstrap        → environments/local/scripts/openbao-bootstrap.sh (the one-time in-cluster bridge; the host-daemon :start/:stop/:reset/:snapshot-restore tasks retired with the daemon)
(ADR 0016)                local:openbao:verify          → environments/local/scripts/openbao-verify.sh
openbao-snapshot          local:openbao:snapshot         → environments/local/scripts/openbao-snapshot.sh (the in-cluster restore bundle)
export-approval-pubkey    attestation:export-pubkey      inline: cosign public-key --key openbao://approval-key --outfile attestation/cosign-approval.pub
approve                   attestation:sign               → attestation/scripts/attestation-sign.sh
verify-approval           attestation:verify             → attestation/scripts/attestation-verify.sh
consume                   frontend:deploy                → deploy/frontend/scripts/frontend-deploy.sh
(new, T7b1-followup)      frontend:seed                  → ci/scripts/registry-seed.sh deploy/frontend/Dockerfile
(new, T7b3)               frontend:build                 → deploy/frontend/scripts/frontend-build.sh
(Plan B M1, ADR 0019)     frontend:vet                   inline: timoni mod vet ./deploy/frontend/timoni --name cv-frontend (the `timoni` hk step's manual entry point)
(T7a; deleted T7b1)       ci:taskrun                     — replaced by `mise run frontend:build` / `tkn pipeline start build-scan-approve`
(T7a; T7c Inc.0)          local:tekton:install           → environments/local/scripts/tekton-install.sh (verify release.lock SHA-256 → apply local file); local:tekton:wait added
(T7c Inc.1a)              local:flux:bootstrap           → environments/local/scripts/flux-bootstrap.sh (cosign-verify chart digest → helm upgrade --install → apply FluxInstance); local:flux:status
(new, T7b0)               local:zot:wait                 inline: kubectl --context orbstack -n zot wait --for=condition=Available deploy/zot
(T7b0; retired T7c Inc.1a) local:zot:install/uninstall   — deleted; environments/local/flux/zot-sync.yaml (a Flux Kustomization) reconciles zot now
check / fix               check / fix                    unchanged
(future)                  local:bootstrap               aggregate → local:openbao:bootstrap + …
```

## Target tree

```
toolbox/
├── CLAUDE.md  README.md  TODOS.md
├── mise.toml  hk.pkl  pitchfork.toml
├── .ls-lint.yml                                      structure + naming (Phase 1a)
├── sgconfig.yml  rules/boundary-*.yml                dependency edges, ast-grep (Phase 1a; boundary-ci.yml — T7a)
│
├── tests/                                            repo-level shared test support (leaf)
│   ├── check-coverage.sh                             diffs suites on disk vs manifest.txt vs `hk … --plan`  (Phase 1c)
│   ├── check-coverage.bats                           mutation tests for the guard itself                    (Phase 1c)
│   ├── manifest.txt                                  committed: every suite (bats + tftest) + its case count (Phase 1c)
│   └── lib/                                          each <concern>/scripts/tests/helper.bash sources these
│       ├── scratch.bash        toolbox_repo_root + scratch_copy — caller names the paths to copy (Phase 1b)
│       ├── registry.bash       free_port + a throwaway zot registry / cosign key / fake image (Phase 1b)
│       ├── assert.bash         assert_exit / assert_file_mode … — added when a suite first needs it
│       └── ports.bash          free_port + frontend_isolation (per-run host port + container name)  (Phase 1d)
│
├── attestation/                                      consumer-agnostic sign + verify seam
│   ├── verdict-approved.cue
│   ├── cosign-approval.pub                           written by `mise run attestation:export-pubkey` only
│   ├── README.md
│   └── scripts/
│       ├── attestation-sign.sh                       (was deploy/frontend/scripts/approve.sh)
│       ├── attestation-verify.sh                     (was …/verify-approval.sh)
│       ├── openbao-preflight.sh                      (moved — signing precondition)
│       ├── lib/attestation.sh
│       └── tests/
│           ├── attestation-sign.bats
│           ├── attestation-verify.bats
│           ├── openbao-preflight.bats
│           └── fixtures/
│
├── deploy/
│   └── frontend/                                     one consumer of an approved image
│       ├── Dockerfile  Dockerfile.dockerignore  README.md
│       ├── pipelinerun.cue                           T7b3 — the per-consumer PipelineRun, plain CUE (not a Timoni module); `cue export -t rev=<sha> -t defsRev=<toolbox-ref>`
│       ├── timoni/                                   Plan B M1 (ADR 0019) — the cv_frontend Timoni MODULE (Deployment/Service/SA + typed #Config); `timoni mod vet` is its schema gate
│       │   ├── timoni.cue  values.cue  images.cue  README.md  timoni.ignore
│       │   ├── templates/{config,deployment,service,serviceaccount}.cue
│       │   ├── tests/invalid-image-digest.cue        negative fixture — a tag-only image.digest MUST fail `timoni mod vet`
│       │   └── cue.mod/{gen,pkg}/                    vendored k8s + timoni.sh/core CUE schemas (committed, `.gitattributes` linguist-generated; `timoni mod vendor k8s`)
│       └── scripts/
│           ├── frontend-build.sh                     T7b3 — `mise run frontend:build` — render + create + watch the pipeline, print the digest + attestation:sign line
│           ├── frontend-deploy.sh                    (was consume.sh)
│           ├── frontend-serve.sh                     (was run.sh — pitchfork entrypoint)
│           ├── lib/frontend.sh
│           └── tests/
│               ├── frontend-build.bats               fake cluster/registry/git/mise; real cue renders pipelinerun.cue
│               ├── frontend-deploy.bats
│               ├── frontend-serve.bats               (one case uses the DEFAULT verify path)
│               ├── timoni-vet.bats                   Plan B M1 — `timoni mod vet` passes clean + rejects the negative fixture
│               └── fixtures/
│
├── environments/
│   └── local/                                        one deployment target
│       ├── main.tf  provider.tf  outputs.tf  variables.tf  versions.tf  README.md
│       │            module "secret_openbao_local" { source = "./openbao" }   ← label kept
│       ├── scripts/                                  the environment owns bringing its units up
│       │   ├── openbao-{bootstrap,reset,snapshot}.sh
│       │   ├── tekton-install.sh                     T7c Inc.0 — verify release.lock SHA-256 → apply the local file (never the URL)
│       │   ├── flux-bootstrap.sh                     T7c Inc.1a — the one-time acyclic bridge: cosign-verify chart digest → helm upgrade --install → apply FluxInstance
│       │   ├── flux-chainsaw.sh  flux-kubeconform.sh T7c — the [k8s] chainsaw wrapper + the kubeconform-flux gate wrapper
│       │   ├── cert-manager-kubeconform.sh           T7c Inc.4 — kubeconform-cert-manager wrapper (vendored cert-manager.io/v1 schemas)
│       │   ├── openbao-verify.sh                     the chart-pin gate (crane digest == lock, then helm template by digest)
│       │   ├── openbao-bootstrap.sh                  the one-time in-cluster bridge: pick source → ns + seal Secret → tofu apply Phase A → init → key-preserving -force restore → assert approval-key unchanged → tofu apply Phase C (ADR 0016)
│       │   ├── openbao-chainsaw.sh                   [k8s] running-state wrapper (skips without a cluster / until the bridge has run)
│       │   ├── openbao-snapshot.sh                   the in-cluster restore bundle (snap + seal.key + root.token)
│       │   └── tests/                                *.bats beside each script (openbao-{verify,bootstrap,chainsaw}, tekton-install, flux-*, mise-env, zot-manifests)
│       ├── flux/                                     T7c — the FluxInstance + operator HelmRelease + Kustomization CRs (ADR 0015)
│       │   ├── flux-instance.yaml                    bridge-owned (excluded from its own sync path — the acyclic anchor)
│       │   ├── flux-operator-helmrelease.yaml        OCIRepository (cosign spec.verify) + HelmRelease — operator self-management
│       │   ├── zot-sync.yaml  ci-runtime.yaml  ci-defs.yaml   Flux Kustomization CRs → environments/local/zot + ci/{runtime,tasks,pipelines}
│       │   ├── cert-manager-helmrelease.yaml         T7c Inc.4a — OCIRepository (digest pin, no verify — static-key sig) + HelmRelease; cert-manager.lock
│       │   ├── cert-manager-pki.yaml                 T7c Inc.4 — a Flux Kustomization CR → ../cert-manager/ (separate from flux-system: unknown-CRD dry-run would deadlock it against the HelmRelease)
│       │   ├── kustomization.yaml  flux-operator.lock  cert-manager.lock
│       │   └── tests/crd-schemas/*.json              vendored Flux/flux-operator v1/v2 schemas for kubeconform-flux
│       ├── cert-manager/                             T7c Inc.4 — the dev PKI (own Flux Kustomization, not flux-system)
│       │   ├── issuers.yaml                          selfSigned root → CA → CA ClusterIssuer → openbao-tls leaf
│       │   ├── kustomization.yaml                    explicit inventory (tests/ sits beside)
│       │   └── tests/crd-schemas/*.json              vendored cert-manager Certificate/ClusterIssuer v1 for kubeconform-cert-manager
│       ├── tekton/
│       │   └── release.lock                          T7c Inc.0 — pinned version + SHA-256 for tekton-install.sh (the controller stays a checksum-gated apply)
│       ├── tests/flux/{flux-reconcile,ci-reconcile}/chainsaw-test.yaml   T7c — [k8s] running-state asserts (flux-chainsaw.sh; one subdir per Test)
│       ├── tests/openbao/chainsaw-test.yaml          [k8s] running-state asserts for the in-cluster OpenBao (openbao-chainsaw.sh)
│       ├── openbao/                                  the in-cluster OpenBao tofu unit (leaf; ADR 0016)
│       │   ├── main.tf (Phase A helm_release + Phase C vault_*)  variables.tf  outputs.tf  versions.tf  provider.tf  README.md
│       │   ├── openbao.lock                          pinned chart + image digests (helm provider can't pin a digest — verify.sh + the bridge enforce it)
│       │   ├── templates/openbao.hcl.tftpl           HTTPS listener + raft + seal "static"
│       │   └── tests/{helm_values,phase_c}.tftest.hcl   Phase A values + Phase C (sops key AES, decrypt-only policy, role scoped to Flux, approval-key rejected)
│       └── zot/                                      T7b0 — interim local registry; reconciled by environments/local/flux/zot-sync.yaml (T7c Inc.1a)
│           └── zot.yaml                              one multi-doc manifest, pinned by image digest, credential-free, GC off
│
├── ci/                                              reusable Tekton build defs, content-digest-pinned (ADR 0014; T7)
│   ├── README.md                                     the job; ci/ (our defs) vs .github/workflows/ (runner + trigger)
│   ├── tasks/
│   │   ├── kustomization.yaml                         T7c Inc.2 — per-path inventory (the 4 Task defs only); keeps Flux's recursive walk out of ci/tests/**
│   │   ├── git-clone.yaml                             T7b1 — blobless shallow clone at a pinned SHA; no script: (step 0: disable-ipv6 sysctl)
│   │   ├── buildkit-build.yaml                        T7a posture — buildctl-daemonless rootless build → push $(IMAGE):$(APP_REVISION); mirror via buildkitd-config workspace
│   │   ├── scan-attach.yaml                           T7b2 — trivy JSON + native CycloneDX (one DB pull) → oras attach ×2 as OCI referrers; never blocks; no script:
│   │   └── gate.yaml                                  T7b3 — trivy convert --exit-code=2 --severity=CRITICAL over scan.json; fails the run on CRITICAL; no privileged step
│   ├── pipelines/
│   │   ├── kustomization.yaml                         T7c Inc.2 — per-path inventory (the Pipeline def only)
│   │   └── build-scan-approve.yaml                    T7b1/T7b2/T7b3 — clone-app → clone-defs → build → scan-attach → gate (shared + buildkitd-config workspaces, retries on clones)
│   ├── runtime/
│   │   ├── kustomization.yaml                         T7c Inc.2 — per-path inventory (namespace + mirror CM only)
│   │   ├── namespace.yaml                             the `ci` namespace (no RBAC)
│   │   └── buildkitd-mirror.yaml                      T7b1-followup — buildkitd.toml ConfigMap: mirror docker.io + gcr.io → in-cluster zot (interim; OrbStack IPv6-egress defect)
│   ├── scripts/
│   │   ├── kubeconform-scan.sh  chainsaw-test.sh      the static + [k8s] hk gates
│   │   ├── registry-seed.sh                           T7b1-followup — host-side crane copy of a Dockerfile's base images into zot (mise run frontend:seed)
│   │   ├── lib/ci.sh                                  repo-root, strict sha256 digest guard, kube-context guard
│   │   └── tests/*.bats + helper.bash                 gate-script skip/fail cases (no [k8s] bats)
│   └── tests/
│       ├── build-pipeline/chainsaw-test.yaml          [k8s]-gated — webhook accepts the 5 defs, no script:, per-Task posture, clone→…→gate DAG + G1 standalone gate TaskRun vs fixtures
│       ├── build-pipeline/fixtures/scan-*.yaml        trivy-report ConfigMaps (critical/clean/malformed) for the G1 gate test
│       └── crd-schemas/{task,pipeline,pipelinerun}_v1.json  vendored Tekton v1 CRD schemas for kubeconform
│
├── modules/
│   └── README.md                                     "reusable, versioned, URL-consumed OT modules only"
│
└── docs/
    ├── designs/
    │   ├── repo-structure.md                         this file
    │   └── digest-as-source-of-truth.md
    └── adr/
        ├── 0012-local-openbao-is-environment-nested.md
        ├── 0013-attestation-seam-is-consumer-agnostic.md
        └── … existing
```

## Enforcement

`hk` steps, all covered by `mise run check`. `ls-lint` + `ast-grep` are in
the `fast` layer (pre-commit); `check-coverage.sh` runs last in the `check`
hook only.

| tool | job | how |
|---|---|---|
| `ls-lint` (`aqua:loeffel-io/ls-lint`; the `hk` `ls_lint` builtin drives the binary) | structure + naming | `.ls-lint.yml`: `.dir` is `kebab-case`; the `.sh` **stem** matches `^[a-z]+(-[a-z]+)+$` (`<domain>-<verb>`, no `\.sh` in the pattern) |
| `ast-grep` (`aqua:ast-grep/ast-grep`) | forbidden-edge + no-embedded-shell **lint** | `sgconfig.yml` + `rules/boundary-*.yml`: **shell** — a literal `deploy/` path in a script upstream of `deploy/` (`attestation/`, `environments/`) or in `ci/` (`boundary-ci.yml`); a `../` climb two-or-more levels or into a named sibling concern (`ci/ deploy/ attestation/ modules/ environments/`); a concern-directory name inside `tests/lib/*.bash`. **yaml** — a `script:` block in a Tekton manifest under `ci/tasks|runtime|pipelines/` (`boundary-no-embedded-shell.yml`). |
| `tests/check-coverage.sh` (Phase 1c, own `hk` step, `check` hook, runs last) | silent-coverage-drop guard | diffs three views: suites found on disk (its own `find`), `tests/manifest.txt` (committed path + case count), and what `hk check --all --plan --json` schedules. A mismatch fails the gate. `tests/check-coverage.bats` mutation-tests it. |

Each phase's `.ls-lint.yml` and `rules/` describe the **then-current** tree.
A temporary exception (a pre-restructure name or a not-yet-fixed edge) is
carried as an explicit `ignores:` / `files:` exclusion with the removing
phase named in the rule file, and listed in that phase's PR body.

### Honest scope

`ls-lint` + `ast-grep` are a **strong lint, not dependency-graph
analysis.** They catch literal path strings and relative climbs in shell.
They do **not** catch: a path assembled from variables, `source "$x"`
resolution, cross-language task references, or most of the **HCL
layer** — `ast-grep` ships no Terraform/HCL grammar, so the tofu unit's
edges (`environments/local/openbao ─╳▶ …`) are not machine-checked here.
The one tofu edge that *is* enforced — no `kubernetes_*` /
`kubernetes_manifest` resource (ADR 0018, in-cluster objects go through Flux
plain-YAML or Crossplane, never tofu) — is the `no-kubernetes-tf` hk step
(`tests/check-tf-boundary.sh`, a `git grep`).
They also do **not** catch **manifest-ref edges** — a Flux `Kustomization`
`spec.path` or a kustomize `resources:` entry pointing across a concern
boundary (e.g. `environments/local/flux/ci-runtime.yaml` → `./ci/runtime`).
The `boundary-*.yml` rules match shell path refs only; the
`environments/local/ ──▶ ci/{runtime,tasks,pipelines}` deployment-composition
edge is **not machine-checked** and relies on review + the per-path
`kustomization.yaml` inventories as the selection control.
The lint is paired with a review checklist for the rest.

A real resolved-dependency-graph check — a generated manifest validated by
`conftest`/OPA (Rego), `tofu graph` for the HCL layer, or CUE/Timoni
schemas expressing the allowed-edge set — is a separate future planning
session, tracked in [`TODOS.md`](../../TODOS.md).

## Migration status

**Complete.** The tree matches the rule; every phase landed green (full
phase list and per-phase verification in [`TODOS.md`](../../TODOS.md),
tasks T1–T6). This table is kept as the record of what moved.

| phase | moves | status |
|---|---|---|
| 0 | this doc + CLAUDE.md rule + 2 ADRs — no code | done |
| 1a | pin `ls-lint` + `ast-grep`; `.ls-lint.yml` + `sgconfig.yml` + `rules/` for the **current** tree; both wired into `hk.pkl` fast layer | done |
| 1b | `tests/lib/{scratch,registry}.bash`; `deploy/frontend/tests/` → `deploy/frontend/scripts/tests/` | done |
| 1c | `tests/check-coverage.sh` + `manifest.txt` + mutation test; `tofu-init` ordered prereq in `hk.pkl` | done |
| 1d | `tests/lib/ports.bash`; every port/container-bound suite takes a free port; `run.sh`/`consume.sh` gain `TOOLBOX_FRONTEND_{HOST_PORT,CONTAINER}` seams | done |
| 2 | local-OpenBao unit → `environments/local/openbao/`; scripts → `environments/local/scripts/` (renamed `openbao-<verb>.sh`), `lib/openbao.sh` + `openbao-snapshot.sh` extracted; root `scripts/` gone; `modules/` → README only | done |
| 3 | mise task namespacing — the `openbao-*` tasks → `local:openbao:*` (+ new `local:openbao:stop`); every `mise run openbao-*` reference rewritten. | done |
| 4 | `attestation/` split out of `deploy/frontend/` (one PR, 4a–4d): the sign/verify/preflight seam → `attestation/`; `consume.sh`/`run.sh` → `frontend-deploy.sh`/`frontend-serve.sh` + the `TOOLBOX_ATTESTATION_VERIFY` seam; `openbao-preflight.sh` 5-state + corrected static-seal advice; `openbao-bootstrap.sh` calls `mise run attestation:export-pubkey` (all boundary rules now closed, no lint exceptions). | done |
| 5 | docs-accuracy sweep — `digest-as-source-of-truth.md`, ADRs 0004/0005/0006/0009/0011, `main.tf` comments re-verified against the moved code; link-check clean | done |
| T7a | new `ci/` concern (skeleton) — `README.md`, `tasks/buildkit-build.yaml`, `runtime/namespace.yaml`, `scripts/tekton-taskrun.sh` + `lib/ci.sh` + `tests/`; `rules/boundary-ci.yml` + `ci` added to the concern-climb sibling list; `ci:taskrun` + `local:tekton:install` mise tasks | done |
| T7c Inc. 2 | `ci/{runtime,tasks,pipelines}` reconciled by Flux — per-path `kustomization.yaml` inventories (`ci/`-owned) + `environments/local/flux/{ci-runtime,ci-defs}.yaml` (deployment policy, `environments/local/`-owned) + the deployment-composition edge above; `frontend-build.sh` hand-apply hints → Flux-bootstrap remedy | done |

## Negative space (deliberately not here)

- **No `environments/production/`** — created when real infra lands; the
  `environments/` seam already exists for it.
- **No repo-level runtime shell lib** — shared runtime logic lives in the
  one concern lib that uses it.
- **No compatibility shims** during the migration — a phase either lands
  whole or does not land.
- **No `modules/*` content** — `modules/` stays empty with a README until a
  genuinely reusable, versioned, URL-consumed module exists (the deferred
  production `secret-openbao` is the first candidate).
