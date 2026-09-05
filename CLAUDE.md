# toolbox — Best Practices

## Abstract

`toolbox` is a GitOps, zero-trust, declarative module library and reference
deployment. `modules/*` are reusable OpenTofu modules — consumed by
downstream repos (e.g. `infra`) via source + version pin — and this repo
also applies them as a working reference/test harness. Every technology
here gets one distinct, non-overlapping job. What's deliberately **not**
used is stated as plainly as what is — negative space is part of the
design, not an afterthought.

## Goals

- Reusable OpenTofu modules, each independently versionable and consumable.
- Zero trust by default: no plaintext secret, default-deny network, admission
  policy on every manifest (mechanics defined per-module, see §7).
- One tool per concern — no two pinned tools compete for the same job.
- `mise` is the only bootstrap step and the only runbook; there is no
  separate ops doc describing steps `mise.toml` doesn't already encode.
- Scripts are minimal, tested, and the last resort — never the first.

## Constraints

- No code inside configuration files (YAML/TOML/HCL/CUE/Pkl/CI pipelines).
  A script is its own file, lintable and testable on its own.
- No cyclic calls between `mise` tasks and scripts — one direction only.
- One primary test tool per layer (§9) — acknowledged partial overlap is
  fine, redundant full coverage by two tools for the same concern is not.
- `hk` is the only git-hook gate. No hook logic lives anywhere else.
- Don't assert a boundary, a mechanism, or a "safe by default" claim that
  hasn't been verified. Where something is genuinely undecided, this doc
  says so — see "Deferred / Not Yet Decided" (§16) — rather than guessing.

## Repo Role

`toolbox` is dual-purpose:

1. **Module library** — each `modules/<type>-<tool>` directory is a
   standalone, independently versioned OpenTofu module, consumed by
   downstream repos (e.g. `infra`) by source URL + version pin.
2. **Reference deployment** — a root composition in this repo applies those
   same modules as a working example and test harness, so a module is never
   published without having been exercised end-to-end at least once, here.

## Tool Boundaries

Every pinned tool gets exactly one job. Where two tools look like they
compete, the boundary below is the resolved answer — see the reasoning
each row links to.

| Tool | Job | Notes |
|---|---|---|
| **OpenTofu** | Owns the full lifecycle (create/upgrade/destroy) of foundational infra: VM, k0s cluster, OpenBao secret engine. | Plan/apply, cloud-agnostic. `k0sctl` is not a competing layer — it's the CLI the `cluster-k0sctl` module wraps, same relationship as `vm-orbstack` wrapping OrbStack. |
| **Flux** | GitOps sync — reconciles manifests (plain YAML, or a Timoni-built OCI artifact) from git/OCI continuously. | Nothing is applied by hand once Flux owns a path. |
| **Flux Operator** | Manages Flux CD's *ongoing* configuration via a declarative `FluxInstance` CRD, once installed. | **Not** a full replacement for `flux bootstrap` — see GitOps Flow below for what still happens once, imperatively. [fluxoperator.dev](https://fluxoperator.dev/get-started/) |
| **Timoni** | Renders + type-checks application manifests from CUE, then publishes them as an OCI artifact (Helm-chart alternative). | A build step (likely CI) produces the artifact; Flux reconciles *that artifact*, not a live Timoni controller object. [timoni.sh/gitops-flux](https://timoni.sh/gitops-flux) |
| **Crossplane** | *Negative space* — pinned, not active. | Would sit at the self-service in-cluster provisioning layer (rival to OpenTofu, not to Timoni) if a concrete need appears. None does yet. |
| **Kyverno** | Admission policy. | Enforcement mechanics (scope, exceptions, webhook-failure mode) not yet defined — design at Kyverno module build time, not asserted here as a slogan. |
| **Cilium** | Network policy, default-deny between workloads, explicit allow only. | Bootstrap allow-list (DNS, API server, git/OCI pulls, OpenBao) needed before default-deny can reconcile anything — defined at Cilium module build time. |
| **OpenBao** | Secret store of record — for anything created *after* OpenBao exists and is unsealed. | The bootstrap secret that first unseals/authenticates to OpenBao is necessarily out-of-band (human-held). |
| **fnox** | Local dev secret access layer, once OpenBao exists. Backend = OpenBao. | Never an independent store of record. fnox→OpenBao is the steady-state direction, not the bootstrap path. |
| **pitchfork** | Local dev daemon supervision only (directory-scoped autostart/autostop). | Repo-policy choice — pitchfork itself can run production daemons; we simply don't use it that way here. |
| **hk** | Sole git-hook gate — concurrent, file-locked, three-way-merge stash-safe. | Config in `hk.pkl`. |
| **mise** | Bootstrap + task runner. | Call graph is one direction only: `mise run check` → `hk check` → individual linters/formatters. `hk.pkl` never calls back into a mise task. |
| **CI build/scan/approve pipeline** | Digest-pinned build → scan+SBOM → cosign-signed approval gate for app repos consumed by this stack (e.g. `cv_frontend`). | Reusable pieces live in `modules/task-buildpacks-build`, `modules/task-trivy-scan`, `modules/task-oras-attach`, `modules/pipeline-build-scan-approve` (Tekton Tasks/Pipeline, parameterized — not app-specific); a per-consumer instance lives in `deploy/<consumer>/` (e.g. `deploy/cv-frontend/`). Design: `docs/designs/digest-as-source-of-truth.md`. Replaces the earlier placeholder `ci-build-frontend` module name/directory. |
| **chainsaw / kubeconform** | Primary test tools for k8s manifests — not strictly exclusive. | See Testing Strategy (§9). |

## GitOps Flow

1. OpenTofu provisions the substrate once (VM → k0s cluster → OpenBao) and
   owns its full lifecycle, including destroy/upgrade.
2. A **one-time imperative bootstrap** installs Flux Operator, applies the
   first `FluxInstance`, and sets up deploy-key/git write-back credentials.
   This step is not eliminated by Flux Operator — `FluxInstance` configures
   Flux once it's running; it doesn't create the git repo or provision
   write-back credentials the way `flux bootstrap` does.
3. After that, Flux Operator manages Flux's *ongoing* configuration
   declaratively via `FluxInstance` — no repeated `flux bootstrap` runs.
4. Flux reconciles everything else from git, pulling Timoni-built OCI
   artifacts where a module uses Timoni for app-manifest packaging.

## Zero Trust

- **Secrets** — no plaintext secret in repo or state. OpenBao is the source
  of truth once it exists; the bootstrap secret that first reaches OpenBao
  is necessarily out-of-band (§ Tool Boundaries).
- **Network** — Cilium default-deny between workloads, explicit allow only.
  Bootstrap allow-list needs are defined at Cilium module build time.
- **Admission** — Kyverno policy intended on every manifest. Enforcement
  scope/exceptions/webhook-failure mode are not yet defined — design at
  Kyverno module build time, not asserted here as done.

## Module Structure & Naming

Naming: `modules/<type>-<tool>` — existing: `vm-orbstack`, `cluster-k0sctl`,
`secret-openbao`, `secret-openbao-local`, plus the Tekton catalog pieces
below.

Standard per-module layout — `main.tf`, `variables.tf`, `outputs.tf`,
`versions.tf`, `README.md`, `tests/*.tftest.hcl` — applies to **OpenTofu
modules specifically**: `vm-orbstack`, `cluster-k0sctl`, `secret-openbao`,
`secret-openbao-local` are OpenTofu modules and get this skeleton.
`secret-openbao-local` is deliberately a sibling of `secret-openbao`, not
a variant of it — one provisions a real cluster secret store (deferred),
the other a disposable local dev daemon consumed by the root composition
today (see `modules/secret-openbao-local/README.md`).

**Resolved exception:** `modules/task-buildpacks-build`,
`modules/task-trivy-scan`, `modules/task-oras-attach`,
`modules/pipeline-build-scan-approve` are Tekton Task/Pipeline YAML, not
OpenTofu — they mirror [tektoncd/catalog](https://github.com/tektoncd/catalog)'s
kind-first, versioned convention instead (`<kind>/<name>/<version>/`),
parameterized so they're reusable across any future app, not one consumer.
A per-consumer instantiation (PipelineRun binding + consumer-specific
scripts/tests) lives in `deploy/<consumer>/` (e.g. `deploy/cv-frontend/`),
matching this repo's own Repo Role split (`modules/` reusable, a root
composition applies them) extended to a new resource kind rather than
inventing a separate pattern. This replaces the earlier placeholder
`ci-build-frontend` module — see `docs/designs/digest-as-source-of-truth.md`
for the full design.

## Testing Strategy

One primary tool per concern — acknowledged partial overlap, not a strict
non-overlapping claim:

| Layer | Tool | Notes |
|---|---|---|
| k8s manifests, static | kubeconform | Schema validation, no cluster needed, fast pre-merge gate. |
| k8s manifests, live behavior/policy | chainsaw | End-to-end in a real/test cluster; runs after kubeconform passes. |
| OpenTofu modules | `tofu test` (`.tftest.hcl`) | Native test framework. |
| Shell scripts | bats | Every script gets one. |

Harness prerequisites (isolated test cluster, rendered-manifest source, CRD
schema fetch for kubeconform, controllers/policies installed + readiness
checks/timeouts/cleanup for chainsaw) are defined when the first
k8s-manifest-bearing module is built — not fully speced yet.

## mise: Bootstrap & Runbook-as-Config

`mise install` is the only bootstrap step. Operational steps live as
`[tasks]` in `mise.toml`, not in a separate runbook doc — the config IS the
runbook. A mise task may call a script; a script may call mise tasks; never
both directions on the same path (no cycles).

## hk: Git Hook Gating

`hk.pkl` is the only place hook logic is declared: shellcheck, bats,
lint/format per touched filetype. mise exposes an equivalent task
(`mise run check`) running the identical checks for manual/CI invocation —
one definition, two entry points, never duplicated logic.

## pitchfork: Local Daemon Supervision

Dev-only, directory-scoped (e.g. `kubectl port-forward`, a tofu-managed VM
watcher). Declarative process definitions, autostart/autostop on `cd` into
the repo. Never a production workload — that's a repo-policy choice, not a
tool limitation.

## Secrets: fnox vs OpenBao

OpenBao is the backend/source of truth. fnox is configured (`fnox.toml`) to
read from it, injecting secrets into the local shell/mise environment for
dev use. fnox is a client, never a store of record. The initial secret that
unseals/authenticates OpenBao itself is out-of-band by necessity — fnox→
OpenBao is the steady-state direction, not the bootstrap path.

## Scripts Policy

Before writing a script: check for an existing tool in the stack, then a
`mise.toml` task, only then write a script. One script = one file, one job.
`#!/usr/bin/env bash` + `set -euo pipefail`, shellcheck-clean, bats-tested.
Config files reference scripts by path — never embed them.

## CI Build/Scan/Approve Pipeline

Designed and phased in `docs/designs/digest-as-source-of-truth.md`
(supersedes the earlier `ci-build-frontend` placeholder): buildpacks build
→ trivy scan+SBOM → cosign-signed approval gate, backed by OpenBao Transit
for key custody. Phase 1 runs as GitHub Actions + GHCR (no cluster); Phase
2+ moves to Tekton Pipelines/Chains + `zot` on OrbStack's built-in k8s.
[Pipelines-as-Code](https://pipelinesascode.com/) (not raw Tekton
Triggers/EventListener) remains the already-researched *webhook-triggering*
mechanism for if/when this pipeline moves from on-demand to
webhook-driven — it owns webhook ingestion itself and matches events to
`PipelineRun`/`Pipeline` YAML stored in-repo, replacing the separate
Triggers/EventListener/TriggerBinding/TriggerTemplate stack. Not yet built
as of this note; the design doc's Build Phases is the authoritative
sequencing.

## Deferred / Not Yet Decided

Stated explicitly rather than guessed:

- **Crossplane** — pinned, inactive. No boundary assigned until a concrete
  self-service in-cluster provisioning need appears.
- **Pipelines-as-Code** — pinned/researched, not yet wired. The CI
  build/scan/approve pipeline (`docs/designs/digest-as-source-of-truth.md`)
  runs on-demand/manually triggered through Phase 3; webhook-driven
  triggering via Pipelines-as-Code is a later addition, not required to
  prove the pipeline itself.
- **Tekton Triggers/EventListener** — not used; if/when webhook-driven
  triggering is built, Pipelines-as-Code replaces this stack outright.
- **`flux bootstrap`** — not eliminated, only reduced to a one-time step
  (operator install + first `FluxInstance` apply + deploy-key/git
  write-back setup). Flux Operator replaces the *ongoing* config path only.
- **pitchfork in production** — not used here; dev-only by policy.
- **fnox as a store of record** — not used; OpenBao only.
- **Kyverno/Cilium enforcement mechanics** — scope, exceptions,
  webhook-failure mode, and default-deny bootstrap allow-list are undefined
  until those modules are built.
- **Testing harness prerequisites** — isolated test cluster, schema
  sources, readiness/timeout/cleanup semantics — undefined until the first
  k8s-manifest-bearing module is built.
- **AI-agent MCP integration** (mise/hk/pitchfork/Flux Operator each ship an
  MCP server) — deferred entirely. An earlier pass proposed committing
  `.mcp.json`/`.codex/config.toml` by default; adversarial review found real
  defects (mise's MCP server needs an experimental flag; hk's default root
  behavior was unverified; pitchfork's behavior with zero daemons
  configured was untested; and a repo cannot self-grant Codex's
  `trust_level = "trusted"` — that's a host/user-side grant). This becomes
  a separate follow-up task, gated on smoke-testing each server for real
  before any config is committed.

## Verification / Definition of Done

For any change touching this repo:

- `mise run check` (the hk-equivalent task) passes.
- Module changes carry a `tests/*.tftest.hcl`.
- k8s manifest changes carry a kubeconform + chainsaw test.
- New scripts carry a bats test.

## Skill routing

When the user's request matches an available skill, invoke it via the Skill
tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec
