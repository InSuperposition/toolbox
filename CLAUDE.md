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
  - **No Tekton `script:` blocks.** A Tekton Task step is a pinned
    `command` + `args` — never an embedded `script:`. Anything a CLI
    invocation can't express (format guards, verification, the digest
    resolution `oras resolve` does at the operator boundary) lives in
    `ci/scripts/*.sh`, shellcheck-clean and bats-tested, and runs from
    there. Machine-checked by `rules/boundary-no-embedded-shell.yml`.
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
| **Crossplane** | *Negative space* — pinned, not active. The **provision** stage of the in-cluster pipeline (render → reconcile → enforce → provision; ADR 0018). | Creates the backing infra a consumer *declares* it needs (bucket/DB/queue/DNS as a CR), if ever activated — trigger `TODOS.md` T-X1, **not** a directory count. Layered above the substrate, delivered by Flux, consumes OpenBao creds; never co-owns a resource, never wraps a substrate module in `provider-terraform`. tofu `kubernetes_*` / `kubernetes_manifest` resources are **banned** (`no-kubernetes-tf` hk step). |
| **Kyverno** | Admission policy. | Enforcement mechanics (scope, exceptions, webhook-failure mode) not yet defined — design at Kyverno module build time, not asserted here as a slogan. |
| **Cilium** | Network policy, default-deny between workloads, explicit allow only. | Bootstrap allow-list (DNS, API server, git/OCI pulls, OpenBao) needed before default-deny can reconcile anything — defined at Cilium module build time. |
| **cert-manager** | In-cluster PKI for the **local dev cluster** — issues the TLS server cert the in-cluster OpenBao listener needs (T7c Increment 4, ADR 0016). | A Flux-reconciled **helper** component (chart + images digest-pinned in `environments/local/flux/cert-manager.lock`; no runtime `spec.verify` — cert-manager signs with a static key, the digest is the pin, ADR 0001). Dev uses a selfSigned root → CA → `openbao-tls` leaf chain (the leaf applies once the 4b bridge creates ns `openbao`); **production** points the leaf's `issuerRef` at a real backend (ACME / org intermediate / OpenBao PKI) — the CA and every leaf unchanged. Unlike OpenBao (OpenTofu-owned substrate, ADR 0015), a helper behind the GitOps loop is fine — nothing secret-bearing depends on its reconcile being tofu-driven. |
| **OpenBao** | Secret store of record — for anything created *after* OpenBao exists and is unsealed. | Local dev: an in-cluster tofu-owned raft StatefulSet (`environments/local/openbao/`, ADR 0016 — supersedes the ADR 0010 machine-global pitchfork daemon). Auto-unseals from a static seal key mounted as a k8s Secret; the on-machine `0600` restore-bundle files (`seal.key`, `root.token`) in `~/.local/state/toolbox/openbao/snapshots/` are the disaster / genesis path (ADR 0011 custody model). `mise [env]` injects `VAULT_ADDR` (ClusterIP HTTPS), `VAULT_CACERT`, `VAULT_TOKEN`. The out-of-band requirement is real for the *deferred production* `secret-openbao` module, not the local one. |
| ~~**fnox**~~ | **Removed 2026-09-07 (ADR 0011).** Was the local dev secret access layer (backend = OpenBao). `fnox set`/`fnox remove` silently rewrite `fnox.toml`, and its keychain items trigger a GUI password prompt when read by another binary. The one bootstrap secret it held (the root token) is now a `0600` file. | — |
| **pitchfork** | Local dev daemon supervision only (directory-scoped autostart/autostop). | Repo-policy choice — pitchfork itself can run production daemons; we simply don't use it that way here. |
| **hk** | Sole git-hook gate — concurrent, file-locked, three-way-merge stash-safe. | Config in `hk.pkl`. |
| **mise** | Bootstrap + task runner. | Call graph is one direction only: `mise run check` → `hk check` → individual linters/formatters. `hk.pkl` never calls back into a mise task. |
| **CI build/scan/approve pipeline** | Digest-pinned build → scan+SBOM → cosign-signed approval gate for app repos consumed by this stack (e.g. `cv_frontend`). | Build is a **distroless Node image** from `deploy/frontend/Dockerfile` (`docker buildx` in Phase-1 CI; Phase-2 is **daemonless rootless BuildKit** in-cluster — `buildctl-daemonless.sh`, ADR 0014, `TODOS.md` T7). `docs/adr/0007`. Reusable pieces: `ci/tasks/{buildkit-build,trivy-scan,oras-attach}.yaml` + `ci/pipelines/build-scan-approve.yaml`, distributed as digest-pinned OCI bundles (ADR 0014, parameterized — not app-specific); a per-consumer `PipelineRun` lives in `deploy/<consumer>/` (e.g. `deploy/frontend/`). Full design: `docs/designs/digest-as-source-of-truth.md`. |
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

- **Secrets** — no plaintext secret in **repo or tofu state**. OpenBao is
  the source of truth once it exists. For the **local dev** daemon its
  bootstrap secrets (root token, recovery key, static-seal key) are `0600`
  files in `~/.local/state/toolbox/openbao/`, beside the raft store they
  protect — the machine is the trust boundary (ADR 0011). "Out-of-band by
  necessity" holds for the deferred production `secret-openbao` module, not
  the local one.
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
a deferred module with a different lifecycle). The local OpenBao daemon
(ADR 0010/0011) traces clean: all three secrets are `0600` files, restart
and reboot auto-unseal, and the only manual case (disaster `-force`
restore) uses the snapshot's own bundle.

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

## File Placement

Full spec, the concern DAG, the target tree, and the migration status:
`docs/designs/repo-structure.md` (ADR 0012, 0013).

The rule:

1. Every top-level concern directory has **one owner** and a declared list
   of the concerns it **may depend on**.
2. A file lives with the concern that **owns** it — not by "lowest
   containing directory".
3. Allowed dependency edges are explicit and machine-checked in
   `mise run check` (`ls-lint` + `ast-grep`, an honestly-scoped lint —
   literal path strings, relative climbs, `source`/exec of a literal — not
   graph analysis).

The concerns: `tests/` (repo-level shared test support, leaf) · `attestation/`
(the sign/verify seam — never names a consumer) · `ci/` (reusable Tekton
defs → digest-pinned OCI bundles — never names a consumer; ADR 0014,
Phase 2) · `deploy/frontend/` (one image consumer) · `environments/local/`
(one deployment target — owns its `openbao/` tofu unit and the scripts that
bring it up) · `modules/` (reusable, versioned, URL-consumed OpenTofu
modules only — empty + README today).

The rule is in force and the tree matches it — the phased restructure
(`TODOS.md` T1–T6, `docs/designs/repo-structure.md` § Migration status) is
complete. `ls-lint` + `ast-grep` enforce the placement + edge rules with
**zero exceptions** (only `**/tests/**` is exempt from the concern-climb
rule — fixtures reach across concerns by design).

## Module Structure & Naming

`modules/` holds **reusable, versioned, URL-consumed OpenTofu modules
only** — nothing else. It is empty today (a README states the rule); the
deferred production `secret-openbao` is the first candidate. The local dev
OpenBao is **not** a `modules/` entry — it is a tofu unit under
`environments/local/openbao/`, owned by that environment (ADR 0012).

A published module's standard layout is `main.tf`, `variables.tf`,
`outputs.tf`, `versions.tf`, `README.md`, `tests/*.tftest.hcl`. A tofu
unit nested in an environment gets the same skeleton minus the version
pin.

Script files are named `<domain>-<verb>.sh` where `<domain>` is the tool
(`openbao-bootstrap.sh`), never the directory — see § File Placement and
§ Scripts Policy.

**Tekton definitions are NOT `modules/` entries** (ADR 0014, supersedes an
earlier carve-out). The reusable Task/Pipeline defs live in the `ci/`
concern (`ci/tasks/`, `ci/pipelines/`, `ci/runtime/`) and are distributed
as **digest-pinned OCI bundles** (`tkn bundle push` → registry digest; a
`PipelineRun` references them through the bundles resolver, `@sha256:`
pinned; cosign-signable like any artifact). Version is the OCI digest, not
a path segment. The per-consumer `PipelineRun` (binding one consumer's
params + the pinned bundle digests) lives in `deploy/<consumer>/`. The
Tekton *controller* install and `zot` are vendored upstreams →
`environments/local/` (a Flux `OCIRepository`/`Kustomization`), not `ci/`.
Full design: `docs/designs/digest-as-source-of-truth.md`; phasing:
`TODOS.md` T7a–T7d.

## Testing Strategy

One primary tool per concern — acknowledged partial overlap, not a strict
non-overlapping claim:

| Layer | Tool | Notes |
|---|---|---|
| k8s manifests, static | kubeconform | Schema validation, no cluster needed, fast pre-merge gate. First user: `ci/` (T7a) — via `ci/scripts/kubeconform-scan.sh` (the `-schema-location` template collides with hk's own), Tekton has no standalone validator so the Task is checked against a v1 CRD schema vendored from the pinned release at `ci/tests/crd-schemas/`. |
| k8s manifests, live behavior/policy | chainsaw | End-to-end in a real/test cluster; runs after kubeconform passes. First user: `ci/` (T7a) — `[k8s]`-gated via `ci/scripts/chainsaw-test.sh` (skips, never fatal, without an orbstack cluster + Tekton — GitHub runners have no OrbStack; a documented departure from `[docker]`). |
| OpenTofu units | `tofu test` (`.tftest.hcl`) | Native framework; tests in `<unit>/tests/`. |
| Shell scripts | bats | Every script gets one, in `<concern>/scripts/tests/*.bats` beside the script. |

Layout: each concern's `.bats` live in `scripts/tests/` next to the scripts
they cover. Shared bats primitives (a free-port / isolation helper, a
scratch-dir copy, a throwaway zot registry) live in repo-level
`tests/lib/*.bash`. Each `scripts/tests/` has a `helper.bash` that walks up
to the checkout root (`mise.toml` marker) and sources them; a `.bats` file
reaches the lib with `load helper` — no `BATS_LIB_PATH`, no mise `[env]`
coupling. A suite that binds a port or names a container takes a fresh one
per test (`free_port`, `frontend_isolation`) and scopes teardown to its own
daemon/container, so parallel `mise run check` across worktrees never
collides. `tests/check-coverage.sh` (its own `hk` step, runs last in the `check`
hook) diffs three views — the suites it finds on disk, the committed
`tests/manifest.txt` (path + case count), and what `hk check --all --plan
--json` schedules — so an `hk` glob edit or a moved test file that
silently drops a suite fails the gate. `tests/check-coverage.bats`
mutation-tests the guard. Full spec: `docs/designs/repo-structure.md`.

Harness prerequisites: `ci/` (T7a) is the first concern with k8s manifests
and sets the initial shape — CRD schemas **vendored** from the pinned
Tekton release (not fetched at lint time), chainsaw creating an ephemeral
namespace per test, a `k8s_available()` skip-guard. The fuller harness
(isolated test cluster, rendered-manifest source, readiness/timeout/cleanup
policy, in-cluster trivy DB) is speced when T7b builds the full pipeline.

## mise: Bootstrap & Runbook-as-Config

`mise install` is the only bootstrap step. Operational steps live as
`[tasks]` in `mise.toml`, not in a separate runbook doc — the config IS the
runbook. A mise task may call a script; a script may call mise tasks; never
both directions on the same path (no cycles).

Task names are namespaced `<environment>:<domain>:<verb>` (or
`<domain>:<verb>`) — `local:openbao:bootstrap`, `local:openbao:snapshot`,
… (`docs/designs/repo-structure.md` § mise task map). `check` / `fix` stay
top-level. A task body is a single inline command unless it carries real
logic (loop / conditional / error classification / multi-step invariant) —
only then a script (§ Scripts Policy).

## hk: Git Hook Gating

`hk.pkl` is the only place hook logic is declared: shellcheck, bats,
lint/format per touched filetype. mise exposes an equivalent task
(`mise run check`) running the identical checks for manual/CI invocation —
one definition, two entry points, never duplicated logic.

## CI check gate & merge policy

`.github/workflows/check.yml` runs the full `mise run check` matrix on
every push and every PR to `main` — the same `hk` `check` hook, invoked
the same one way. **Report-only:** `main` has no branch protection (on a
solo repo `enforce_admins` is a false choice — off exempts every push, on
adds a break-glass ritual). A red `check` is a notification.

PRs merge **squash-only** — the repo setting disables merge-commit and
rebase merges and auto-deletes the head branch. So every push to `main` is
exactly one commit, and `check.yml` running on that commit *is* full
per-commit `git bisect` safety, for free. That is why there is **no**
per-commit history-replay workflow (the former T9b — resolved by policy,
not tooling). The squash commit takes the **PR title + PR body**, so the
PR description is the durable commit message — write it as one.

## pitchfork: Local Daemon Supervision

Dev-only, directory-scoped (e.g. `kubectl port-forward`, a tofu-managed VM
watcher). Declarative process definitions, autostart/autostop on `cd` into
the repo. Never a production workload — that's a repo-policy choice, not a
tool limitation.

## Secrets: the local in-cluster OpenBao (ADR 0011/0016)

The local dev OpenBao runs in-cluster (`environments/local/openbao/`,
ADR 0016). `openbao-bootstrap.sh` (the one-time bridge) brings it up and,
on every successful run, writes the restore bundle's values to `0600`
files in `$OPENBAO_STATE_DIR` (`~/.local/state/toolbox/openbao/`), beside
the `snapshots/` bundle:

| file | role | held by |
|---|---|---|
| `seal.key` | static-seal key — the pod auto-unseals from the mounted `openbao-seal` Secret; this is the on-machine copy for a re-run | the machine (0600) |
| `root.token` | the restore bundle's original root token — `mise [env]` injects it as `VAULT_TOKEN` | the machine (0600) |
| `tls/ca.crt` | the live cert-manager dev CA — `mise [env]` injects it as `VAULT_CACERT` (public, no secrecy) | the machine |
| `snapshots/` | the raft snapshot + `seal.key` + `root.token`, written together — the disaster / genesis bundle. Copy off-machine. | the machine (0600) |

No keychain, no `fnox` (removed — it rewrote `fnox.toml` and its keychain
items prompted for a password). There is **no memorized secret and no
recurring manual step**: the pod auto-unseals from the Secret on every
start; a pod restart or cluster return needs no action. The one manual case
is the disaster `-force` restore — re-run `mise run local:openbao:bootstrap`,
which restores from the `snapshots/` bundle. After the host daemon's
retirement (ADR 0016) that bundle is the **only** genesis path; a lost
bundle with no host daemon is the "resume signing" disaster (fresh init →
re-export pubkey → re-sign → re-record).

For app secrets created *after* OpenBao is up, OpenBao is the store of
record; a client that reads them into the dev env is a future concern
(none exists yet).

## Scripts Policy

Before writing a script: check for an existing tool in the stack, then a
`mise.toml` task, only then write a script. One script = one file, one job.
`#!/usr/bin/env bash` + `set -euo pipefail`, shellcheck-clean, bats-tested.
Config files reference scripts by path — never embed them.

- A script lives in its concern's `scripts/` directory, never loose at a
  concern root or the repo root (§ File Placement).
- Named `<domain>-<verb>.sh`, `<domain>` = the tool, not the folder
  (`openbao-bootstrap.sh`, `attestation-sign.sh`). Stem matches
  `^[a-z]+(-[a-z]+)+$`.
- A `mise` task body stays a single inline command **unless** it has a
  loop, a conditional, error classification, or a multi-step sequence with
  an invariant — only then does it get a script.
- Shared runtime shell → `<concern>/scripts/lib/<domain>.sh`,
  self-contained. No repo-level runtime lib. A production script never
  sources from a `tests/` path.

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

- **Crossplane** — pinned, inactive. Boundary now defined (ADR 0018): the
  **provision** stage — creates consumer-*declared* backing infra as a CR,
  layered above the tofu substrate, delivered by Flux. Activation trigger
  `TODOS.md` T-X1 (a consumer declares infra it does not own); not sequenced
  before then. The per-consumer namespace bundle stays Flux plain-YAML
  meanwhile; tofu `kubernetes_*` resources are banned.
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
- **Local OpenBao unseal-key storage** — RESOLVED (ADR 0011/0016): static
  seal auto-unseal from a `0600` `seal.key` (mounted in-cluster as a k8s
  Secret); the on-machine restore-bundle files are `0600`; `fnox` and the
  keychain are gone. The production `secret-openbao` module keeps the
  out-of-band requirement.
- **Local OpenBao runs in-cluster** — SHIPPED (ADR 0016). The loopback
  listener could not serve pods (the blocker in front of T8), so
  `environments/local/openbao/` is now a tofu-owned single-replica raft
  StatefulSet: `openbao-bootstrap.sh` (the one-time bridge) picks a source
  (a live host daemon, an off-machine restore bundle, or the disaster
  runbook), creates ns + the seal Secret, `tofu apply`s the `helm_release`,
  runs `bao operator init` once, does a key-preserving
  `raft snapshot restore -force` (**`approval-key` never rotated** — a fresh
  init strands every past approval attestation), hard-asserts the
  in-cluster `approval-key` matches `attestation/cosign-approval.pub`, then
  `tofu apply`s Phase C (the `sops` `aes256-gcm96` key, a decrypt-only
  policy, the k8s-ServiceAccount auth method + a `flux_sops` role).
  `approval-key` + the `transit` mount are never tofu-managed
  (`openbao-verify.sh` greps the `.tf`). The host `pitchfork` daemon is
  retired. **Deferred (Plan B):** the reusable `modules/secret-openbao`
  extraction; wiring `--sops-vault-configmap` onto the `FluxInstance`.
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
