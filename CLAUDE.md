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
  - **Named carve-out:** `deploy/frontend/Dockerfile` is the one
    hand-authored Dockerfile in this repo. It packages the external
    consumer `cv_frontend` as a distroless Node image
    (`docs/adr/0007-distroless-dockerfile-not-buildpacks.md`). It is a
    minimal two-stage build — two `RUN` lines, no shell
    logic — which is the industry-standard declarative form, not the "RUN
    soup" this rule targets. Both base images are pinned by digest. Any
    real build logic (evidence-gathering, the approval decision) still
    lives in its own tested script per the Scripts Policy, never in the
    Dockerfile.
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
| **OpenBao** | Secret store of record — for anything created *after* OpenBao exists and is unsealed. | The *root token* that first authenticates to OpenBao is machine-held (fnox → OS keychain, shipped in T3). The *unseal key* is currently human-held — **under review**: for the single-operator local dev daemon (which reseals on every process restart) a memorized/hand-copied key is friction with little threat-model benefit (the machine is the trust boundary; the root token already lives on it; the sibling `infra` repo stores its unseal key). Storing it machine-side + auto-unseal is a planning task (§ Deferred). The out-of-band requirement is real for the *deferred production* `secret-openbao` module, not asserted for the local one. |
| **fnox** | Local dev secret access layer, once OpenBao exists. Backend = OpenBao. | Never an independent store of record. fnox→OpenBao is the steady-state direction, not the bootstrap path. |
| **pitchfork** | Local dev daemon supervision only (directory-scoped autostart/autostop). | Repo-policy choice — pitchfork itself can run production daemons; we simply don't use it that way here. |
| **hk** | Sole git-hook gate — concurrent, file-locked, three-way-merge stash-safe. | Config in `hk.pkl`. |
| **mise** | Bootstrap + task runner. | Call graph is one direction only: `mise run check` → `hk check` → individual linters/formatters. `hk.pkl` never calls back into a mise task. |
| **CI build/scan/approve pipeline** | Digest-pinned build → scan+SBOM → cosign-signed approval gate for app repos consumed by this stack (e.g. `cv_frontend`). | Build is a **distroless Node image** from `deploy/frontend/Dockerfile` (`docker buildx` in Phase-1 CI; the Phase-2 Tekton in-cluster builder is an open spike — `TODOS.md`). `docs/adr/0007`. Reusable pieces: `modules/task-<builder>-build`, `modules/task-trivy-scan`, `modules/task-oras-attach`, `modules/pipeline-build-scan-approve` (Tekton Tasks/Pipeline, parameterized — not app-specific); a per-consumer instance lives in `deploy/<consumer>/` (e.g. `deploy/frontend/`). Full design: `docs/designs/digest-as-source-of-truth.md`. |
| ~~**buildpacks**~~ | **Removed 2026-09-06.** Was the image build tool; the pivot replaced it with a hand-authored distroless Dockerfile (carve-out above). No longer pinned in `mise.toml`. | — |
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
  of truth once it exists. The first secret that authenticates to it (the
  root token) is machine-held (fnox → OS keychain). Whether the *unseal
  key* is human-held or machine-held for the **local dev** daemon is under
  review — see § Tool Boundaries (OpenBao) and § Deferred. "Out-of-band by
  necessity" holds for the deferred production `secret-openbao` module, not
  automatically for the local one.
- **Network** — Cilium default-deny between workloads, explicit allow only.
  Bootstrap allow-list needs are defined at Cilium module build time.
- **Admission** — Kyverno policy intended on every manifest. Enforcement
  scope/exceptions/webhook-failure mode are not yet defined — design at
  Kyverno module build time, not asserted here as done.

## Operational Lifecycle Trace (planning gate)

Before any plan that introduces or touches a **secret** or a **long-lived
process** is considered done, trace and write down its full lifecycle —
this is a planning step, not post-implementation verification:

| Stage | Question |
|---|---|
| **Bootstrap** | Created by what, stored where, who/what holds it. |
| **Process restart** (crash / `pitchfork restart` / manual) | What state is lost? What manual step gets back to working? |
| **Machine reboot** | Comes back automatically, or a human runs something? |
| **Disaster** (disk loss / corrupted store / lost secret) | Recovery path, what must have been kept elsewhere, blast radius. |

For each stage name **who holds what** and **every recurring manual step**.

A recurring manual step, or a memorized secret with no machine-side
storage, is a **flaw to fix in the plan** — not a feature to document —
*unless* there is a stated threat-model reason (production, multi-operator,
a deferred module with a different lifecycle). The
"§ Deferred — Local OpenBao unseal-key storage" entry exists because this
trace was skipped for T3/T6: the daemon reseals on every restart and the
unseal key was left human-held, which reads as "memorize a key, re-enter
it after every reboot".

## Docs layout

Three kinds of doc, one job each:

| Doc | Holds | Tense |
|---|---|---|
| `docs/designs/*.md` | What a system **is** — its current architecture | present |
| `docs/adr/NNNN-slug.md` | **Why** a hard-to-reverse, non-obvious call was made | past |
| `TODOS.md` | **Open** work, phase sequencing, planning-session triggers | future |

Rules:

- Revise a design doc **in place**, present tense. Never strike-through a
  superseded decision inside it — write a new ADR and mark the old one
  `Status: superseded by ADR-NNNN`.
- ADRs are minimal: a title plus one to three sentences (format:
  `~/.claude/skills/grill-with-docs/ADR-FORMAT.md`, which the `diagnose` /
  `improve-codebase-architecture` skills read). Only for decisions that are
  hard to reverse **and** surprising without context **and** a real
  trade-off — not every choice.
- Task status lives in `TODOS.md` and git history, not in the design doc.

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

**Resolved exception:** `modules/task-kaniko-build` (was
`task-buildpacks-build` before the 2026-09-06 pivot),
`modules/task-trivy-scan`, `modules/task-oras-attach`,
`modules/pipeline-build-scan-approve` are Tekton Task/Pipeline YAML, not
OpenTofu — they mirror [tektoncd/catalog](https://github.com/tektoncd/catalog)'s
kind-first, versioned convention instead (`<kind>/<name>/<version>/`),
parameterized so they're reusable across any future app, not one consumer.
A per-consumer instantiation (PipelineRun binding + consumer-specific
scripts/tests) lives in `deploy/<consumer>/` (e.g. `deploy/frontend/`),
matching this repo's own Repo Role split (`modules/` reusable, a root
composition applies them) extended to a new resource kind rather than
inventing a separate pattern. Full design:
`docs/designs/digest-as-source-of-truth.md`.

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
dev use. fnox is a client, never a store of record. fnox→OpenBao is the
steady-state direction, not the bootstrap path.

**Bootstrap secrets (local dev daemon):** the root token is stored via fnox
(OS keychain) by `scripts/bootstrap-openbao.sh` — steady-state, not a
manual `export`. The unseal key is currently *not* stored (printed once,
hand-copied), which means a memorized key on every daemon restart — a known
friction flaw, tracked in § Deferred. Do not add a design that assumes the
operator has the unseal key to hand for routine operations; the disaster
`-force` snapshot restore is the one legitimate exception (it needs the
snapshot's *own* original unseal key, kept with the snapshot).

## Scripts Policy

Before writing a script: check for an existing tool in the stack, then a
`mise.toml` task, only then write a script. One script = one file, one job.
`#!/usr/bin/env bash` + `set -euo pipefail`, shellcheck-clean, bats-tested.
Config files reference scripts by path — never embed them.

## CI Build/Scan/Approve Pipeline

Architecture: `docs/designs/digest-as-source-of-truth.md`. Decisions and
rationale: `docs/adr/`. Open work and phase sequencing: `TODOS.md`.

Shape: distroless Dockerfile build (`docs/adr/0007`) → trivy scan + SBOM +
scan-report referrers → cosign-signed approval gate backed by OpenBao
Transit (`docs/adr/0004`). Phase 1 (shipped) runs as GitHub Actions + GHCR
on a native `linux/arm64` runner; Phase 2+ moves to Tekton
Pipelines/Chains + `zot` on OrbStack's k8s (`docs/adr/0003`, deferred).
[Pipelines-as-Code](https://pipelinesascode.com/) (not raw Tekton
Triggers/EventListener) remains the already-researched *webhook-triggering*
mechanism for if/when this pipeline moves from on-demand to webhook-driven.

## Deferred / Not Yet Decided

Stated explicitly rather than guessed:

- **Crossplane** — pinned, inactive. No boundary assigned until a concrete
  self-service in-cluster provisioning need appears.
- **Pipelines-as-Code** — pinned/researched, not yet wired. The CI
  build/scan/approve pipeline runs on-demand/manually triggered through
  Phase 3; webhook-driven triggering via Pipelines-as-Code is a later
  addition, not required to prove the pipeline itself.
- **Tekton Triggers/EventListener** — not used; if/when webhook-driven
  triggering is built, Pipelines-as-Code replaces this stack outright.
- **`flux bootstrap`** — not eliminated, only reduced to a one-time step
  (operator install + first `FluxInstance` apply + deploy-key/git
  write-back setup). Flux Operator replaces the *ongoing* config path only.
- **pitchfork in production** — not used here; dev-only by policy.
- **fnox as a store of record** — not used; OpenBao only.
- **Local OpenBao unseal-key storage** — T3 shipped the root token
  machine-held (fnox) but the unseal key printed-once-and-hand-copied, so
  every daemon restart needs a memorized key. A real friction flaw (missed
  during T6 planning). Direction: store it machine-side + auto-unseal (the
  `infra` repo already does this) — for a single-operator local box the
  machine is the trust boundary and the root token is already on it, so
  separate custody buys ~nothing. Needs a planning session: CLAUDE.md
  wording carve-out, storage mechanism (fnox vs a raw `security` item),
  and the interaction with the disaster `-force` snapshot restore (which
  legitimately still needs the snapshot's own original unseal key). The
  production `secret-openbao` module keeps the out-of-band requirement.
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
- Changes introducing or touching a secret or a long-lived process carry a
  completed **Operational Lifecycle Trace** (§ above) in the plan or PR.

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
