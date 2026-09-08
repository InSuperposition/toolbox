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
  `tasks/{git-clone,buildkit-build}.yaml`, `pipelines/build-scan-approve.yaml`,
  `runtime/`, and the `kubeconform` / `chainsaw` gate scripts (`TODOS.md`
  T7). The distribution mechanism (`tkn bundle` vs Flux `OCIRepository`) is
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
```

| concern | owns | may depend on |
|---|---|---|
| `tests/` | repo-level shared test support (`lib/`, the coverage guard) | nothing — leaf; concern-agnostic (helpers take paths as args) |
| `attestation/` | the sign + verify + preflight seam, `verdict-approved.cue`, `cosign-approval.pub` | `tests/lib` |
| `deploy/frontend/` | one consumer of an approved image: build, deploy, serve | `attestation` (the verify seam, via env), `tests/lib` |
| `environments/local/` | one deployment target: the tofu composition, the orchestration scripts that bring its units up | its own `openbao/` unit, `tests/lib`; calls `attestation:export-pubkey` as a task |
| `environments/local/openbao/` | the local-OpenBao **tofu unit** only | `tests/lib` (for its `.tftest.hcl`) — leaf |
| `ci/` | reusable Tekton Task/Pipeline defs → digest-pinned OCI bundles; `ci/runtime/` namespace; the bundle-push + taskrun scripts | `tests/lib`. **Never names a consumer** (like `attestation/`) — machine-checked (`rules/boundary-ci.yml`). `deploy/<consumer>/` consumes `ci/` bundles by digest via a pinned `PipelineRun`. Tekton controller + `zot` installs are `environments/local/`, not `ci/`. |
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
openbao-bootstrap         local:openbao:bootstrap        → environments/local/scripts/openbao-bootstrap.sh
openbao-up                local:openbao:start            inline: pitchfork start global/openbao
(new)                     local:openbao:stop             inline: pitchfork stop global/openbao
openbao-reset             local:openbao:reset            → environments/local/scripts/openbao-reset.sh
openbao-snapshot          local:openbao:snapshot         → environments/local/scripts/openbao-snapshot.sh
openbao-snapshot-restore  local:openbao:snapshot-restore inline: bao operator raft snapshot restore
export-approval-pubkey    attestation:export-pubkey      inline: cosign public-key --key openbao://approval-key --outfile attestation/cosign-approval.pub
approve                   attestation:sign               → attestation/scripts/attestation-sign.sh
verify-approval           attestation:verify             → attestation/scripts/attestation-verify.sh
consume                   frontend:deploy                → deploy/frontend/scripts/frontend-deploy.sh
(T7a; deleted T7b1)       ci:taskrun                     — replaced by `tkn pipeline start build-scan-approve`
(new, T7a)                local:tekton:install           inline: kubectl --context orbstack apply --server-side -f <pinned release.yaml>
(new, T7b0)               local:zot:install              inline: kubectl --context orbstack apply -f environments/local/zot/zot.yaml
(new, T7b0)               local:zot:wait                 inline: kubectl --context orbstack -n zot wait --for=condition=Available deploy/zot
(new, T7b0)               local:zot:uninstall            inline: kubectl --context orbstack delete -f environments/local/zot/zot.yaml --ignore-not-found
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
│       └── scripts/
│           ├── frontend-deploy.sh                    (was consume.sh)
│           ├── frontend-serve.sh                     (was run.sh — pitchfork entrypoint)
│           ├── lib/frontend.sh
│           └── tests/
│               ├── frontend-deploy.bats
│               ├── frontend-serve.bats               (one case uses the DEFAULT verify path)
│               └── fixtures/
│
├── environments/
│   └── local/                                        one deployment target
│       ├── main.tf  provider.tf  outputs.tf  variables.tf  versions.tf  README.md
│       │            module "secret_openbao_local" { source = "./openbao" }   ← label kept
│       ├── scripts/                                  the environment owns bringing its units up
│       │   ├── openbao-bootstrap.sh
│       │   ├── openbao-reset.sh
│       │   ├── openbao-snapshot.sh                   (extracted from the mise task)
│       │   ├── lib/openbao.sh                        state-dir resolution, daemon wait-loop, atomic 0600 write
│       │   └── tests/
│       │       ├── openbao-bootstrap.bats
│       │       ├── openbao-reset.bats
│       │       ├── openbao-snapshot.bats
│       │       ├── mise-env.bats
│       │       ├── zot-manifests.bats               T7b0 — static invariants of environments/local/zot/zot.yaml
│       │       └── fixtures/
│       ├── openbao/                                  the tofu unit only (leaf)
│       │   ├── main.tf  variables.tf  outputs.tf  versions.tf  README.md
│       │   ├── templates/openbao.hcl.tftpl
│       │   └── tests/
│       │       ├── config_render.tftest.hcl
│       │       ├── keys.tftest.hcl
│       │       └── policies.tftest.hcl
│       └── zot/                                      T7b0 — interim local registry (kubectl apply; Flux-managed in T7c/T7d)
│           └── zot.yaml                              one multi-doc manifest, pinned by image digest, credential-free, GC off
│           (T7c: → environments/local/tekton/ + zot/ as Flux OCIRepository/Kustomization)
│
├── ci/                                              reusable Tekton build defs, content-digest-pinned (ADR 0014; T7)
│   ├── README.md                                     the job; ci/ (our defs) vs .github/workflows/ (runner + trigger)
│   ├── tasks/
│   │   ├── git-clone.yaml                             T7b1 — blobless shallow clone at a pinned SHA; no script:
│   │   └── buildkit-build.yaml                        T7a posture — buildctl-daemonless rootless build → push $(IMAGE):$(APP_REVISION)
│   ├── pipelines/
│   │   └── build-scan-approve.yaml                    T7b1 — clone-app → clone-defs → build (one shared workspace); scan/gate T7b2/T7b3
│   ├── runtime/
│   │   └── namespace.yaml                             the `ci` namespace (no RBAC)
│   ├── scripts/
│   │   ├── kubeconform-scan.sh  chainsaw-test.sh      the static + [k8s] hk gates
│   │   ├── lib/ci.sh                                  repo-root, strict sha256 digest guard, kube-context guard
│   │   └── tests/*.bats + helper.bash                 gate-script skip/fail cases (no [k8s] bats)
│   └── tests/
│       ├── build-pipeline/chainsaw-test.yaml          [k8s]-gated — webhook accepts the defs, no script:, posture + DAG
│       └── crd-schemas/{task,pipeline}_v1.json        vendored Tekton v1 CRD schemas for kubeconform
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
resolution, cross-language task references, or **anything in the HCL
layer** — `ast-grep` ships no Terraform/HCL grammar, so the tofu unit's
edges (`environments/local/openbao ─╳▶ …`) are not machine-checked here.
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
