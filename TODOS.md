# TODOS

Open work, phase sequencing, and planning-session triggers (CLAUDE.md §
Docs layout). Completed work lives in commit messages, PRs, and ADRs —
this file keeps only a git-log-density pointer to it, not a diary.

## Table of contents

**Reference / runbooks** (no priority band — standing procedures, not
open work):

- `How to rotate the T5 approval-key` — the rotation procedure, done once
  so far.

**P2**

- *secrets/auth*
  - `Dev CA (toolbox-dev-ca) rotation runbook + rotationPolicy decision`
  - `Auth + multi-member DX` — deferred, trigger + pre-picked direction
    recorded (includes the folded-in gh token expiry gap)
  - `T-DR` — declarative disaster recovery for the in-cluster OpenBao
  - `zot registry auth` — credential-free today, real auth deferred
  - `Flux / registry CA trust — could a mesh solve this structurally?`
  - `SPIRE — phased workload-identity rollout` — planning-session output,
    Phases 0-3, cross-referenced from the four items above it
- *tofu modules*
  - `Retrofit vm-orbstack, cluster-k0sctl, secret-openbao to digest-pinning`
- *Tekton/CI*
  - `Promotion boundary for build-scan-approve` — new, surfaced by T8's
    eng review (Codex outside voice)
- *Kyverno/Cilium*
  - `Cilium — planning session needed`
  - `Plan B — Timoni + Kyverno + Crossplane boundary` — shipped M1→X1→K1→M3,
    Deferred table is the open half
  - `Kyverno module — accumulating design inputs`
- *cv_frontend hosting*
  - `Decide public hosting for cv_frontend`

**P3**

- *Tekton/CI*
  - `A real resolved-dependency-graph boundary check`
  - `T7a-follow-up — rename frontend-*/attestation-* to <tool>-<verb>`
  - `R5 — OCI-bundle distribution of the ci/ defs` (now also owns signing
    the bundles, folded in from the old T8 scope)
  - `Build reproducibility (SOURCE_DATE_EPOCH, independent rebuild
    verification)` — split out from the old T8 scope
  - `T7d — production repoint`
  - `Pin-drift guard: host mise.toml vs ci/tasks/* step images`
  - `openbao-verify.bats's online() helper checks only one of two registries`
  - `Tekton Dashboard`
  - `T10 — VEX hardening`
  - `Publish a multi-arch image once a real amd64 consumer exists`
- *Kyverno/Cilium*
  - `Kyverno ImageValidatingPolicy for real admission-time enforcement` —
    now specifically the production-cluster instantiation
- *tooling cleanup*
  - `Remove crane from the stack entirely`
  - `Upgrade cosign signing to public trust`

## Recently closed

Newest first. Git-log density — commit/PR references, not a transcript.
Full detail lives in the referenced PRs, ADRs, and commit messages.

- **T8 — build provenance — DONE** (PR #51; reshaped by PR #49/#50 —
  `/plan-eng-review`, 2 Codex outside-voice passes, live spikes). Rejected
  installing Tekton Chains (upstream alpha) and a hand-assembled
  "SLSA-shaped" predicate (not real SLSA, tag-race prone). Ships instead:
  a new `ci/tasks/provenance-sign.yaml` Task signs BuildKit's own native
  SLSA v1 provenance output (already pushed unsigned by `build`'s
  `attest:provenance=` opt) with a second OpenBao Transit key
  (`chains-provenance-key`), reusing the `cosign attest` + OpenBao pattern
  `attestation-sign.sh` already proves out for `approval-key` — zero new
  controllers. Evidence-only (not a second enforced gate); wired into
  `attestation-sign.sh`'s evidence display, hard-blocking on missing
  evidence like SBOM/scan already do. Runs `build → scan-attach →
  provenance-sign → gate` (sequential, avoids a concurrent-PVC-mount
  question).
  **Auth, live-verified against the real cluster, not mocked:** a
  dedicated `provenance-signer` ServiceAccount
  (`ci/runtime/provenance-signer-sa.yaml`), bound only to this
  PipelineTask (`deploy/frontend/pipelinerun.cue` `taskRunSpecs`),
  authenticates to a new OpenBao k8s-auth role (`chains_provenance`,
  `environments/local/openbao/main.tf`) scoped to `chains-provenance-key`
  sign+read only — confirmed live: signs `chains-provenance-key`, denied
  (403) on `approval-key`. Found and fixed mid-implementation: the
  role's `audience` (matching the existing `flux_sops` role's own
  pattern) requires an explicitly-projected custom-audience SA token —
  the k8s default-automounted token's audience does NOT match and login
  fails 403 (same latent gap likely exists, still unexercised, in
  `flux_sops` — G1/SOPS is deferred, never live-tested).
  **Zero embedded shell** (CLAUDE.md § Constraints) — every step is one
  pinned CLI call. The extract-a-JSON-field problem that would normally
  force a script was solved by `stdoutConfig` (Tekton, alpha-gated —
  `environments/local/scripts/tekton-install.sh` now flips
  `enable-api-fields` after the checksum-verified base install): a
  step's stdout is duplicated to a file BY TEKTON ITSELF, and a later
  step's `args` reference it via `$(steps.<name>.results.<name>)` —
  verified live with 3 throwaway TaskRuns before committing to the
  design. One new pinned image (`jq`, well-known/single-purpose) for the
  one field-extraction step; no custom multi-tool image.
  **Also found, unrelated, flagged not fixed:** `openbao-verify.bats`'s
  `online()` helper checks only `ghcr.io`, not `quay.io` (which the
  script also needs) — a `quay.io` outage makes an unrelated
  anti-rotation-guard test falsely report failure. Own P3 entry, below.
  Scope split per Gall's Law: OCI-bundle signing → `R5`; build
  reproducibility → its own entry; the promotion-boundary gap Codex
  found → its own entry (below), both P2, not part of this item.

- **T-ADR9 — ADR-0009 pitchfork demo had no reachable registry — RESOLVED**
  (PR #45 escalation → PR #46 fix). T7c R4's GHCR package deletion broke the
  ADR-0009 pitchfork demo's restart path (no reachable registry, and no
  route to the in-cluster zot either). Resolved by retiring the demo
  outright — [ADR 0023](docs/adr/0023-retire-adr-0009-pitchfork-demo.md):
  `frontend-deploy.sh`/`frontend-serve.sh`/`current-image.txt` deleted,
  `frontend:publish` is the only consumer now. Named cost kept, not papered
  over: **the launch-time re-verify property has no replacement** —
  Kyverno's admission-time check is the only re-verify point left, and it
  never re-checks an already-admitted pod.

- **T7 — Tekton pipeline + distribution — DONE.**
  - T7a — rootless BuildKit feasibility spike + `ci/` concern extraction
    (PR #9); T7a-follow-up hygiene renames/lint/bats (PR #11) — its one
    still-open item (the `frontend-*`/`attestation-*` rename) is promoted
    to its own section below.
  - T7b0–T7b3 — interim zot (PR #14), in-cluster git-clone→build Pipeline +
    the hermetic-build fix (Z2+N1+N4, PR #15), scan-attach (PR #16), the
    blocking CRITICAL gate + CUE-rendered `PipelineRun` (PR #17). Live
    end-to-end demo 2026-09-09.
  - T7c Increments 0/1a/1b/2/3 — Flux-managed Tekton controller install,
    self-managing flux-operator, `ci/{runtime,tasks,pipelines}` + zot
    reconciled from `main`, ADR 0015 doc sweep (PRs #18–#22).
  - T7c Increment 4 — in-cluster OpenBao raft StatefulSet, ADR 0016
    (PRs #23–#30).
  - T7c distribution tail R1a→R1b-ii-c — HTTPS zot, trust-manager CA
    bundle, host CA trust, the `crane`→`oras` swap (PRs #36–#40).
  - R2/R3/R4 (2026-09-14) — repointed M3 delivery to zot (PR #41); one
    documented end-to-end acceptance run, and a live-found
    `kyverno-reports-controller` CA gap **fixed in PR #42**; the GitHub
    Actions build workflow + both GHCR packages retired (PRs #43–#44). The
    T7 arc is fully closed. R5 and T7d are the two deliberately-deferred
    tails — promoted to their own sections below, not lost.
  - The other live finding worth keeping: R4's GHCR deletion broke the
    ADR-0009 demo's restart path the same day — see T-ADR9, above.

- **T9a — `mise run check` in CI — DONE** (PR #7, `7ae5ad0`).
  `.github/workflows/check.yml` runs the full `hk` `check` hook
  (shellcheck, tofu, cue, ls-lint, ast-grep, bats, check-coverage) on every
  push/PR, report-only, no branch protection (solo repo). **Revisit
  trigger:** a second committer joins the repo — then a PR-gated
  `required_status_checks` flow earns its keep.

- **Repo restructure — strict ownership boundaries — DONE (P0–P5).**
  File-placement rule applied repo-wide in phased PRs, `mise run check`
  green at every phase. Design + rationale: ADR 0012, ADR 0013,
  `docs/designs/repo-structure.md`.

- **Scripts-policy audit reduction pass — DONE** (Round 1 on
  `feat/openbao-machine-global-and-gate`; Round 2 — 3 pushes on `main`:
  `ebdaf92`, `813509b`, a consistency-only push 3). Kept
  `openbao-preflight.sh`'s 5-state floor, `attestation-sign.sh`'s
  orchestration shape, and `frontend-serve.sh`'s `docker run &` + trap
  dance as reviewed-correct; dropped the cosign-stderr classifier and the
  `oras discover` predicate-diff loop (~35 lines, net −21).

## Open work

### How to rotate the T5 `approval-key` (procedure — done once, 2026-09-06)

The first `approval-key` was rotated on 2026-09-06 (commit `bcbb862`)
because it was provisioned in an AI session whose bootstrap output was
transcript-visible. Procedure for any future rotation:

```
mise run local:openbao:reset            # stops daemon, wipes raft store + 0600 secret files + tfstate
mise run local:openbao:bootstrap        # fresh approval-key; regenerates seal.key / root.token /
                                  #   recovery.key (all 0600); rewrites cosign-approval.pub
git add attestation/cosign-approval.pub && git commit
```

No `fnox.toml` / keychain step — the secrets are `0600` files (ADR 0011).
Every attestation signed with the old key stops verifying against the new
`cosign-approval.pub` — re-run `mise run attestation:sign` for any image whose
approval must persist. `.../rotate` on the same key would keep old versions
verifiable but the *exported* public key still changes, so a full reset is
simpler while nothing real depends on the key.

### Dev CA (`toolbox-dev-ca`) rotation runbook + `rotationPolicy` decision — P2

**What:** Define how the `toolbox-dev-ca` CA `Certificate`
(`environments/local/cert-manager/issuers.yaml`) renews and re-keys, and a
runbook for it.

**Why:** cert-manager renews the CA on its duration cycle. With the default
`privateKey.rotationPolicy` (key reuse) a renewed CA cert keeps validating
existing leaves, but a *key* rotation (`rotationPolicy: Always`, or a manual
re-key on compromise) briefly leaves the old and new roots mutually
non-validating — every leaf (`openbao-tls` today, `zot-tls` after T7c R1b-ii)
and every distributed CA bundle breaks mid-rotation. Undefined today.

**Context:** trust-manager (T7c R1b-i) tracking the live `toolbox-dev-ca`
Secret covers the renew-same-key case for the Kyverno bundle. The open part
is key rotation: cert-manager's trust-bundle-then-issuer ordering, whether to
run overlapping roots, and a `kubectl`-level runbook. Surfaced by the Codex
outside voice on the T7c R1b-i eng review (2026-09-10); R1b-ii carries a
one-line "acknowledged limitation" pointer here.

**Depends on / blocked by:** nothing. Not blocking T7c R1b-i or R1b-ii.
Production (`environments/production/`, T7d) needs a real answer; the local
dev cluster's `rebuild → re-approve → re-pin` disaster path is the interim.

### Auth + multi-member DX — DEFERRED, no trigger yet

**Status (2026-09-08):** Deferred, not scheduled. YAGNI — there is one
developer, the machine is the trust boundary (ADR 0011), and nothing open
(T7b included) needs this. An `/office-hours` pass on 2026-09-08 concluded
there is no design session to run until a trigger below fires. This entry
exists to record the trigger and the pre-picked direction so a future
session does not re-derive them.

**The two gaps — kept distinct, `auth` alone is ambiguous:**

| Principal | Authentication (which principal is acting) | Authorization (what it may do) |
| --- | --- | --- |
| **Human approver** | `attestation-sign.sh` presents the **root token**; OpenBao authenticates the token, not a person. `approvedBy` is a typed string (`gh api user` / `$USER`), unverified. | Root token ⇒ every path. Wants a policy scoped to `transit/sign/approval-key` only. |
| **Pipeline pod** (T7b+) | **Corrected 2026-09-14** (this description was stale — no `docker-registry` Secret exists in the current manifests, verified against every `ci/*.yaml` and `deploy/frontend/*`): `git-clone` is anonymous HTTPS only, zot is credential-free by design, and no Role/RoleBinding is granted (`ci/runtime/namespace.yaml`'s own comment states the intent is no k8s API identity at all — a live double-check pass found that intent is not yet backed by an actual `automountServiceAccountToken: false` on any TaskRun/PipelineRun spec in `ci/` or `deploy/frontend/`; flagged as its own small gap, not fixed here). The real live gap is that pods have **effectively zero** useful identity today, not a mis-scoped one. | Nothing scoped today because nothing is authenticated today. Wants push-one-repo / clone-two-repos and nothing wider, whenever a real credential is needed. |

**Why it is safe to defer:** the zero-trust claim ("possession of the
private key is the access control") collapses today to "possession of one
`0600` file on one machine" — which ADR 0011 accepts as correct for a
single operator. The 2026-09-06 T5 eng review filed this as
known-deferred P2, not urgent. The only forcing function for the human gap
is a second approver.

**Folded in from the retired "Local OpenBao unseal-key storage" section:**
its one live loose end was gh token expiry. **Corrected 2026-09-14:** the
actual live credential is the human operator's own `gh auth token`, read
live at sign-time by `attestation/scripts/attestation-sign.sh:111` (not a
stored pipeline-pod Secret — none exists) — it has no rotation/renewal
story this repo manages; `gh` CLI's own local credential refresh is the
only thing standing behind it today. Covered by trigger 2 below (a shared
runner / CI service account is the real fix, once pods carry any
credential at all).

**Reopen when ANY of:**

1. A second person needs to sign an approval verdict (the real trigger for
   the human gap).
2. The build/scan pipeline moves to a shared runner, a CI service account,
   or any host where a personal `gh` token is the wrong credential (the
   trigger for the pod gap) — note T7b on the local single-user OrbStack VM
   does **not** cross this line; T7a's interim `gh`-token Secret is fine
   there.
3. `zot` replaces GHCR (T7d) and needs its own identity model wired.
4. T8 (build provenance, reshaped 2026-09-14 — no Chains) — narrower and
   already scoped: adds a `chains-provenance-key` Transit policy denying it
   `approval-key`, plus a dedicated ServiceAccount + k8s-auth role scoped
   to that key only. `environments/local/openbao/main.tf` does **not**
   already have this — it's new work T8 adds; T8 does not need this whole
   session regardless.

**Pre-picked direction (evaluate these first, don't restart from zero):**

- *Human authn+authz* — either (a) an OpenBao auth method (userpass / OIDC
  / AppRole) issuing a token scoped to `transit/sign/approval-key`, or
  (b) cosign **keyless / Fulcio** so the approver identity is an OIDC
  identity carried in the signature itself and there is no OpenBao userpass
  scheme to maintain. (b) overlaps "Upgrade cosign signing to public trust"
  (this file, later) — decide them together.
- *Pod authn+authz* — an OpenBao **k8s auth method** (pod authenticates by
  ServiceAccount, gets short-lived narrowly-scoped registry + git creds),
  vs. a scoped machine PAT in a sealed Secret. Kyverno can enforce *which*
  SA may mount the Secret but is not the identity primitive and its module
  is unbuilt. **Updated 2026-09-14:** SPIFFE/SPIRE is no longer dismissed
  outright — a phased, cheap-to-execute rollout exists
  (`SPIRE — phased workload-identity rollout`, below) that closes real
  gaps incrementally without needing this whole session to reopen. This
  item stays formally deferred (no trigger below has fired) but the
  direction is de-risked; see that entry before re-deriving from zero.
- *New-member DX target* — `git clone` → `mise run attestation:sign` with
  no runbook step, idempotent on a fresh machine.

**Context:** Surfaced by the 2026-09-06 T5 eng review. See
`docs/designs/digest-as-source-of-truth.md` § Trust boundary and
`docs/adr/0004-approval-key-openbao-transit-not-acl.md`. T5's shipped
interim auth: `attestation-sign.sh` signs with the root `VAULT_TOKEN` (the
`0600` `root.token` file, ADR 0011) and, for a non-local registry,
`gh auth token | cosign login` into an isolated `DOCKER_CONFIG`;
`approvedBy` is self-asserted.

**Effort (when reopened):** planning ~1 session; implementation ~1-2d human
**Priority:** P2 · **Depends on:** a trigger above.

### T-DR — declarative disaster recovery for the in-cluster OpenBao — P2, planning session

**What:** design the full recovery story for the in-cluster OpenBao once the
host daemon is gone (Plan A O2/O3): a **cluster-sourced** snapshot bundle
(host snapshots omit the cluster-created `sops` key material), an OpenTofu
**state backup / import** path for the external `openbao.tfstate` (a
re-`tofu apply` after machine loss fails creating the already-enabled k8s
auth backend), an **off-machine copy verification** step, and whether
scheduled backup goes **declarative** — CSI `VolumeSnapshot` of the raft PVC
(verify OrbStack's default StorageClass exposes the snapshot API), a k8s
`CronJob` running `bao operator raft snapshot save`, or the current CLI
script retargeted.

**Why:** Plan A ships only ADR 0016's plain-language statement ("genesis is
forever restore-from-bundle; lost bundle + lost host = the resume-signing
disaster") plus one bundle-only `[k8s]` restore test. The actual recovery
system is unbuilt, and the backup-mechanism choice resurfaces at Plan B's
`snapshot_schedule` preset.

**Depends on:** Plan A merged. **Overlaps:** Plan B O5 (`snapshot_schedule`).
**Priority:** P2. Surfaced by `/plan-eng-review` 2026-09-10 (+ Codex #6/#7).

### zot registry auth — planning session — P2

**What:** design real auth for the local (and eventual production) zot. T7b0
ships it **credential-free** on the single-user OrbStack VM (stated threat model:
all cluster writers are the operator's). **Why:** a credential-free registry lets
any cluster workload push an image or attach a referrer; `attestation-sign.sh`
selects evidence by `last`-of-artifactType. Fine solo, not fine with a second
operator or a shared cluster. **Options to weigh:** static htpasswd Secret,
zot's OIDC/LDAP, an OpenBao-issued short-lived credential, **or SPIFFE/SPIRE
mTLS (4th candidate, now the lead one)** — zot has first-party documented
support for extracting identity from an X.509-SVID's URI SAN
([zotregistry.dev authn-authz](https://zotregistry.dev/v2.1.14/articles/authn-authz/)),
no beta caveat. See `SPIRE — phased workload-identity rollout` below, Phase 1.
**First step:** decide whether this folds into the deferred "Auth + multi-member
DX" session (likely) or stays separate. **Depends on:** T7b0 (zot exists).
**Triggers with:** a 2nd operator, a shared cluster, or
`environments/production/`.

### Flux / registry CA trust — could a mesh or another pinned tool solve this structurally? — planning session — P2

**What:** R1b-ii-c hit a real wall: `flux push artifact` has no CA-file
override for a private registry CA (`~/.claude/plans/t7c-distribution-t7d.md`
§ "R1b-ii-c PRE-PLAN"), and the interim (`--insecure-registry`, scoped to one
call) is accepted only as time-boxed, not a destination. The per-CLI-flag
approach (this session's fix) treats each tool as its own trust boundary —
worth a dedicated session asking whether a **structural** fix moves the trust
decision below the application layer entirely, so individual CLIs stop
needing to know about the dev CA at all.

**Why:** a mesh sidecar/ztunnel terminating and re-establishing mTLS between
workloads (and potentially between the host and cluster) could make
in-cluster registry traffic trusted by construction, independent of whether
`flux push`/`crane`/whatever-comes-next happens to expose a CA flag — closes
this whole class of gap instead of solving it once per tool.

**Candidates researched (real sources, not pattern-matching from training
data — same discipline as the R1b-ii-c pre-plan):**

- **Cilium's Mutual Authentication — checked, does NOT answer this item.**
  Confirmed Beta, and Cilium's own docs state it "only works within a
  Cilium-managed cluster and is not compatible with an external mTLS
  solution" ([docs.cilium.io mutual-authentication](https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/)) —
  pod-to-pod only. The actual pain here (`flux push`/`oras`/
  `frontend-publish.sh` running **on the Mac host**, outside the cluster)
  is exactly the case this feature rules out. Not the answer to this
  item's own question.
- **SPIFFE/SPIRE host-side agent — the candidate that does answer it.**
  SPIRE supports non-Kubernetes node attestation (`join_token`, `x509pop`)
  for bare hosts/VMs ([spiffe.io SPIRE concepts](https://spiffe.io/docs/latest/spire-about/spire-concepts/)).
  A SPIRE Agent on the dev Mac issues host CLI processes their own
  X.509-SVIDs via the Workload API, which zot's SPIFFE mTLS support (see
  "zot registry auth", above) consumes directly — one mechanism closes
  both this item and that one, without waiting on Cilium's beta maturity.
  See `SPIRE — phased workload-identity rollout` below, Phase 2.
- **Kyverno** — anything beyond admission policy (already scoped, ADR
  0020/0022) relevant to registry trust distribution. Not investigated
  further — no lead found.
- **Crossplane** — pinned/inactive (ADR 0018); the "provision" stage has
  no bearing on this (transport trust, not backing-infra provisioning).

**Depends on:** R1b-ii-c's per-tool fixes landing first (this session)
— they're needed regardless of whether a mesh answer ever ships, and prove
the problem is real before reaching for a bigger structural tool.
**Triggers with:** a dedicated planning/research session, not blocking R2–R4.

### SPIRE — phased workload-identity rollout — P2, planning-session output

**What:** a corrected, cited map of every identity boundary in the repo
today, plus an ordered, small-transaction rollout of SPIFFE/SPIRE where it
closes an *already-open* gap — not a rewrite. Full plan:
`~/.claude/plans/let-s-go-with-the-steady-treehouse.md`. Owns and is
cross-referenced from: "zot registry auth", "Flux / registry CA trust",
"Auth + multi-member DX", T8, and the Cilium planning-session entry
(all this file).

**Why now:** the sharpest, most concrete, already-self-diagnosed gap in
the stack — `docs/designs/digest-as-source-of-truth.md` § Trust boundary
— is that the human approver authenticates to OpenBao with the **root
token**, not a scoped identity (`attestation-sign.sh:98-103`). SPIFFE/SPIRE
was previously dismissed stack-wide as "an innovation-token overspend for
one VM" (this file's Auth + multi-member DX entry) — that call was right
for a monolithic all-at-once adoption; it doesn't hold once the rollout is
broken into phases, each cheap and independently revertable, each closing
one named gap.

**Ground truth (2026-09-14), corrected against two stale claims this pass
fixed in place:** OpenBao's k8s-auth `flux_sops` role (`main.tf:188-210`)
already works narrowly and is untouched by any phase below. Tekton build
pods have zero identity of any kind (not a mis-scoped one — see the
Auth + multi-member DX correction above). zot is credential-free by
design. The `var.transit_keys` extension point exists; a generic
`policies` variable does not yet (T8 correction above).

**Per-boundary verdicts (checked against each tool's own current docs,
not pattern-matched from training data):**

- **zot** — ready today. First-party SPIFFE mTLS support, no beta caveat
  ([zotregistry.dev](https://zotregistry.dev/v2.1.14/articles/authn-authz/)).
- **OpenBao** — no native SPIFFE auth method. Vault's own SPIFFE auth
  method is Enterprise-only, irrelevant to OpenBao
  ([developer.hashicorp.com/vault/docs/auth/spiffe](https://developer.hashicorp.com/vault/docs/auth/spiffe/spiffe)).
  Real options: `jwt` auth + JWT-SVID (works today, but JWT-SVIDs are
  bearer tokens — SPIFFE's own spec: proof-of-possession is via TLS for
  X.509-SVID, not achievable the same way for a bearer JWT) vs. `cert`
  auth + X.509-SVID mTLS (stronger, matches "JWT isn't secure enough" —
  but whether OpenBao's `cert` backend extracts identity from a URI SAN
  rather than only CN is **unverified** — Phase 0 spikes this before any
  real wiring).
- **Registry-CA-trust "mesh" question** — Cilium's Mutual Authentication
  is confirmed pod-to-pod only, explicitly incompatible with external/host
  mTLS ([docs.cilium.io](https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/)) —
  does not answer the "Flux / registry CA trust" item's own question. A
  host-side SPIRE Agent (non-k8s node attestation via `join_token`) does —
  see that item's entry above.
- **Tekton Chains** — not viable now, upstream alpha, "not yet functional"
  ([tekton.dev](https://tekton.dev/docs/pipelines/spire/)). T8 does not
  depend on this.

**Phases (each its own PR, gated on the previous phase's verification):**

0. **Spike** — throwaway SPIRE Server + Agent; confirm OpenBao `cert` auth
   extracts a SPIFFE ID from an X.509-SVID's URI SAN. Decides whether
   Phase 3 targets `cert` auth or falls back to `jwt` auth. No production
   wiring; a finding, not code.
1. **SPIRE Server + Agent in-cluster; zot mTLS** — new concern directory
   `environments/local/spire/` (sibling to `openbao/`, same tofu-unit
   skeleton). SPIRE's intermediate cert issued via OpenBao's PKI secrets
   engine as upstream authority (keeps OpenBao as the one root of trust —
   no third independent CA alongside `toolbox-dev-ca` and OpenBao's own
   listener cert). SPIRE Agent DaemonSet, `k8s_psat` attestor. Closes
   "zot registry auth."
2. **Host-side SPIRE Agent** — `join_token` node attestation on the dev
   Mac, `pitchfork`-supervised (never a bare `spire-agent run &`). Host
   CLI tools (`flux push`, `oras`, `frontend-publish.sh`,
   `registry-seed.sh`) present an X.509-SVID to zot instead of per-CLI
   `--ca-file` patchwork. Closes "Flux / registry CA trust."
3. **OpenBao signing identity** — gated on Phase 0. `attestation-sign.sh`
   authenticates via the host SVID → OpenBao `cert` (or `jwt`, if the
   spike fails) auth → a policy scoped to `transit/sign/approval-key`
   only — the root token retires from this one path. Directly answers
   Auth + multi-member DX's trigger #1 (a second approver) ahead of that
   trigger firing, since the mechanism becomes cheap to have ready.
   `flux_sops`'s k8s-auth role is untouched.
4. **Cilium Mutual Authentication** — not scheduled; deferred to the
   Cilium planning-session entry (above), reusing this Phase 1's SPIRE
   Server, never Cilium's bundled one.
   Not scheduled at all: Tekton Chains + SPIRE (upstream not ready — see
   T8's entry).

**Operational Lifecycle Trace (SPIRE Server, required before Phase 1
ships per CLAUDE.md's planning gate):** bootstrap via a tofu unit +
`spire-bootstrap.sh` (intermediate cert from OpenBao PKI, host
`join_token` written `0600`, registration entries declarative via
`spire-register.sh` — never typed by hand); process restart — in-cluster
DB on a PVC survives, host agent restarted + re-attested by `pitchfork`;
machine reboot — both sides autostart, no manual step; disaster — SPIRE's
cert re-issues from OpenBao (already-recoverable root), registration
entries re-apply from the checked-in manifest. No recurring manual step,
no memorized secret — matches the standard ADR 0011 already holds OpenBao
to. Full trace: the plan file above.

**Effort:** planning done (this entry + the linked plan); Phase 0 ~1
session; Phases 1-3 ~S-M each.
**Priority:** P2 · **Depends on:** nothing blocking — Phase 0 can start
any time. Phase 4 depends on the Cilium planning session (above).

### Retrofit vm-orbstack, cluster-k0sctl, secret-openbao to digest-pinning

**What:** Pin the three existing OpenTofu modules' git sources by commit SHA
instead of a mutable tag, matching the pattern proven in the
digest-as-source-of-truth pipeline.

**Why:** Closes the gap this whole design is about — for the modules that
actually provision production infra, not just the CI pipeline wedge.

**Context:** Deliberately out of scope for the pipeline wedge — it proves
the pattern on `deploy/frontend/` first. Once Phase 1-2 are proven, apply
the same `ref=<sha>` convention here.
`docs/adr/0001-digest-is-the-trust-boundary.md` frames git commit SHA as
the digest-equivalent for git-sourced modules.

**Effort:** M
**Priority:** P2
**Depends on:** digest-as-source-of-truth Phase 1-2 landing and proving out

### Promotion boundary for build-scan-approve — P2, planning session

**What:** design a real promotion boundary for the `build-scan-approve`
Pipeline — today `buildkit-build` pushes the image
(`ci/tasks/buildkit-build.yaml`) before `scan-attach`, `gate`, or T8's new
provenance-sign Task even run. A CRITICAL-vuln or unsigned image is
briefly (or, on a failed run, indefinitely) present in the registry
regardless of what any gate later decides.

**Why:** closes a real zero-trust gap this repo's design doc doesn't
currently claim to have. `gate.yaml`'s blocking exit code stops the
*PipelineRun*, not the image's registry presence — a distinction the repo
has not stated plainly anywhere until this review.

**Candidates to weigh:** a staging repo path the image lands in first,
promoted (re-tagged/re-pushed, or a manifest-list flip) to the real path
only after every gate passes; a registry-side quarantine/retention policy;
zot-native support for this pattern (worth checking before building one).

**Context:** surfaced by Codex's outside-voice review of the T8 plan-eng-
review (2026-09-14) — not a new defect, a pre-existing gap in the shipped
`scan-attach`/`gate` design that T8's review happened to notice while
checking a related claim.

**Depends on:** nothing blocking. **Priority:** P2 — affects the existing
scan gate, not just T8; should land before or alongside T8's provenance
work since it's the same pipeline.

### Build reproducibility (SOURCE_DATE_EPOCH, independent rebuild verification) — P3

**What:** land byte-level build reproducibility
(`SOURCE_DATE_EPOCH`, `--output rewrite-timestamp=true`) plus independent
rebuild verification. **Split out from the old T8 scope** (2026-09-14) —
unrelated pacing to provenance signing, no reason to block on it or be
blocked by it.

**Depends on:** T8's provenance work landing first is not required: this
is orthogonal (build determinism, not signing). **Priority:** P3.

### Cilium — planning session needed — P2

**What:** a design session for the Cilium module before it is built — CLAUDE.md
§ Tool Boundaries pins Cilium for "network policy, default-deny between
workloads, explicit allow only" but the mechanics are undefined (§ Deferred).

**Why now:** the T7b1 investigation (2026-09-08) surfaced a cluster-networking
defect that Cilium's datapath choices directly bear on. Findings to carry into
the session:

- **The defect.** On this OrbStack k8s cluster, every pod gets a working
  `AF_INET6` stack + IPv6 interface addresses (`fe80::` link-local, `::1`) and
  kube-dns returns AAAA records — but there is **no routable IPv6 egress** (no v6
  default route in pods; the node's only v6 address is the non-routable ULA
  `fd07:b51a:cc66::2`). CoreDNS's `loadbalance` plugin shuffles the merged
  A/AAAA answer, so any Go registry client that resolves a dual-stack host
  (buildkit / containerd remotes, and zot's own `regclient` — both verified
  live) can pick the AAAA and hard-fail `connect: network is unreachable`
  instead of falling back to the reachable A. ~50% per external image fetch.
- **How Cilium bears on it.** Cilium replaces the CNI. It exposes an explicit
  IPv6 datapath toggle (`ipv6.enabled`), an L7 DNS proxy (`ToFQDNs` policies
  that observe/rewrite A/AAAA), and its own IPAM. Whatever the module decides
  about single- vs dual-stack, and about the DNS proxy, determines whether this
  defect is eliminated, inherited, or papered over. **Open question for the
  session — not a decision here:** should the local (and eventual production)
  Cilium run IPv4-only, dual-stack with real v6 egress, or dual-stack with the
  DNS proxy filtering AAAA? Each has different blast radius, and production may
  genuinely want v6. Do not pre-commit.
- **The `ToFQDNs` angle.** Default-deny egress means `docker.io`, `github.com`,
  `gcr.io`, `ghcr.io`, the OpenBao listener, and the API server all need
  explicit `ToFQDNs` / CIDR allow rules. The A/AAAA set a policy must allow is
  entangled with the single/dual-stack choice above — design them together.
- **Interim (pre-Cilium) is handled in T7b1-followup** (DONE, see the T7
  summary above): Z2
  (seed zot from the host + a `buildkitd.toml` mirror so the build stops
  touching docker.io/gcr.io) + N1 (a `disable-ipv6` privileged step 0 on the
  `git-clone` + `buildkit-build` pods). Revisit once Cilium lands: a **v4-only
  datapath deletes the `disable-ipv6` step entirely** (and shrinks the Kyverno
  "scope `ci` privileged" input to nothing);
  the seed + mirror stays useful as a rate-limit / speed optimization but is no
  longer load-bearing. A dual-stack datapath keeps both load-bearing.
- **The `disable-ipv6` step is spreading — this is the trigger to watch.**
  T7b2 adds it to a 3rd Task (`scan-attach` — `trivy`'s vuln-DB pull is an
  external fetch, `/investigate` option A, "keep it simple for now" — user
  2026-09-08). Every in-cluster tool that reaches an external registry / API
  over this OrbStack CNI needs the same privileged `sysctl` workaround. That
  does not scale. **Two forcing conditions to bring this session forward:**
  (a) a **4th** tool needs `disable-ipv6`, or (b) k0s replaces the OrbStack
  cluster (the substrate OpenTofu owns — VM → k0s → OpenBao). Whichever comes
  first, the Cilium datapath decision (v4-only vs dual-stack + real v6 egress
  vs DNS-proxy AAAA filtering) should be made **then**, and one datapath
  choice retires all N `disable-ipv6` steps + the Kyverno "scope `ci`
  privileged" input at once. Do not add a 4th `disable-ipv6` step without
  re-opening this.
- **Known gap in the `disable-ipv6` step itself** (observed T7b2,
  2026-09-08): step 0's `sysctl` sets the POD netns, but `buildkit-build`'s
  RUN steps (`npm ci`) execute inside `rootlesskit`'s own build-exec
  network namespace, which step 0 does not reach — so `npm ci` still
  occasionally hangs on an unreachable AAAA (~1 run in 4). A pod-netns
  sysctl cannot fix a nested netns; only a datapath with no v6 route at all
  (v4-only Cilium) closes it. Interim mitigation if it gets worse before
  Cilium: `--opt network=host` on the `buildctl build` (RUN steps then
  share the pod netns) or a `buildkitd.toml` `dns` block — both add
  surface, neither is worth it yet.

**Design lenses:** the CNI datapath (single/dual-stack, IPAM, kube-proxy
replacement), the L7 DNS proxy, the default-deny bootstrap allow-list (DNS, API
server, git/OCI pulls, OpenBao — CLAUDE.md § Zero Trust), Hubble observability,
existing-stack fit (OrbStack's current CNI, Flux-reconciled install), and
whether Kyverno's admission webhook and Cilium's policy engine overlap.

**SPIRE note (added 2026-09-14):** Cilium's Mutual Authentication feature
(pod-to-pod mTLS) is backed by SPIFFE/SPIRE, confirmed Beta — "security
model completeness not yet complete"
([Cilium CFP-22215](https://github.com/cilium/design-cfps/blob/main/cilium/CFP-22215-mutual-auth-for-service-mesh.md)).
If this session evaluates it: **reuse the SPIRE Server from
`SPIRE — phased workload-identity rollout` (below) — Cilium's Helm chart
offers to deploy its own SPIRE server, do not use that option.** One
SPIRE Server per cluster, never two (CLAUDE.md § Tool Boundaries — no two
tools compete for one job).

**Depends on:** T7c (local Flux — Cilium installs through it). **Priority:** P2
· runs after the T7 arc, likely alongside the Kyverno module design.

### Plan B — Timoni + Kyverno + Crossplane boundary — P2

**Shipped 2026-09-10, ship arc COMPLETE:** `M1 → X1 → K1 → M3`, each 1 PR
= 1 squash commit — **M1** #31 (`b4c0b0c`, `deploy/frontend/timoni/` CUE
module + `timoni mod vet` gate, ADR 0019); **X1** #32 (`d286867`, ADR
0018 — render→reconcile→enforce→provision pipeline staging, tofu
`kubernetes_*` banned); **K1** #33 (`1dc6e91`, Kyverno v1.19.1 via Flux +
one `ImageValidatingPolicy` gating `cv_frontend` at admission, ADR 0020);
**M3** #34 (`2c6a1e1`, `mise run frontend:publish` host step delivers via
Flux OCIRepository/Kustomization into ns `frontend`, ADR 0021). Live on
`main`: `cv-frontend` runs 1/1 in ns `frontend`, admitted by the approval
policy; `chainsaw-{kyverno,frontend}` pass post-merge.

**Op note:** the interim zot is ephemeral + GC-off — recreate loses
`D_man` → re-run `frontend:publish` + re-pin (like `frontend:seed`).

**Deferred (own triggers):**

| Item | Trigger |
| --- | --- |
| **O4 / O5** — extract `modules/secret-openbao/` (`moved` blocks — `deletion_allowed=false` on `sops`/`extra` keys makes `tofu destroy` fail partway) + `ha` / `awskms`\|`transit` unseal / `snapshot_schedule` / `tls_issuer` presets. **ADR 0017**. | `environments/production/openbao/` becomes real planned work (the true 2nd consumer — one consumer is not a module, `modules/README.md`). ADR 0012 stands until then. O4 planning also picks up a dedicated OpenBao Transit `manifest-signing` key for the M3 artifact. |
| **Crossplane install** (core + `provider-*` + a Composition + its own ADR) | a consumer declares backing infra it does not own (bucket / DB / queue / DNS as a CR) — **not** a directory count. |
| **G1** — Flux SOPS (`--sops-vault-configmap` + ConfigMap + `spec.decryption`) | a named secret needs SOPS decryption. Plan A's Phase C left the OpenBao side (`sops` key, `flux_sops` role) ready. |
| **Manifest authorization** (Codex #7) — scoped RBAC for the `frontend` kustomize-controller SA + a defined rendered-manifest review path (image approval ≠ authz of the manifests around it) | own review/session. |
| **Kyverno `ci`-namespace privilege policies** (PSA scalpel, build-pod securityContext) | `cluster-k0sctl` built + the Cilium planning session done. |
| **`chainsaw-frontend` HTTP-200 assertion** | the cv_frontend Remix v3 boot crash is fixed (cv_frontend repo). |

**Depends on:** Plan A merged (done, `a3b5a24`). **Priority:** P2. Related:
**T-DR** overlaps K1's snapshot needs / O5's `snapshot_schedule`; **T8**
(build provenance, shipped — see "Recently closed," no Chains) ended up
adding its own dedicated `vault_policy` resource directly
(`chains_provenance_sign`, `main.tf`) rather than a generic `policies`
extension point — no such point exists yet. O4 should account for that
shape (one named policy resource per consumer) when it extracts this
unit, not assume a reusable `policies` variable it can preserve.

### Kyverno module — accumulating design inputs — P2/P3, planning session

Collects what the Kyverno module must cover before it is built (CLAUDE.md
§ Tool Boundaries pins Kyverno for admission policy; mechanics are deferred —
§ Deferred). Runs after `cluster-k0sctl` exists (the production cluster —
enforcing policy on the throwaway OrbStack dev cluster is not the point), and
likely alongside the Cilium planning session (this file — the two policy
engines' overlap is an open question there).

Known inputs so far:

- **Scope the `ci` namespace privileged allowance** — duplicates a row
  already in Plan B's Deferred table ("Kyverno `ci`-namespace privilege
  policies", this file, Plan B section above) — see there for the trigger,
  not restated here.
- **Build-pod posture enforcement** (from `ci/README.md` § Residual privilege
  surface). The spike-proven `buildkit-build` `securityContext` ceiling
  (`SETUID`/`SETGID` only, `seccomp: Unconfined`, `allowPrivilegeEscalation`,
  `--oci-worker-no-process-sandbox`) is currently guarded by a chainsaw
  drift-test. A Kyverno policy scoped to `ns=ci` could enforce it at admission —
  deny anything looser, and deny `SYS_ADMIN`/`SYS_PTRACE`/`privileged` on the
  build step outright.
- **ImageValidatingPolicy** — the approval-referrer admission check (its own
  entry below).

**Design lens (from `/investigate`):** prefer Timoni-render / Flux-reconcile for
*delivering* config (git-visible, reviewable); reserve Kyverno for *enforcing*
invariants at admission (deny what shouldn't exist). Do not use Kyverno-mutate
to inject workarounds — an invisible admission rewrite is worse for review than
rendered YAML.

**Depends on:** `cluster-k0sctl` module built; the Cilium planning session (run
first — its datapath choice may delete the `disable-ipv6` input).

### Decide public hosting for cv_frontend

**What:** Choose where the actual public `cv_frontend` site lives for a
hiring manager to visit — separate from any local demo/proof deploy (the
T5b `pitchfork`-supervised Docker container was retired — see
[ADR 0023](docs/adr/0023-retire-adr-0009-pitchfork-demo.md)).

**Why:** Anything running on this dev Mac — whether the earlier
k8s-namespace plan or T5b's retired pitchfork container — is tied to a
single machine staying on, not a reasonable uptime story for a public site.
Candidates worth evaluating: Vercel/Netlify (Remix has first-class
adapters for both), or the eventual `cluster-k0sctl` production cluster
once it exists.

**Context:** T5b deployed/ran `cv_frontend` from a verified image for proof
purposes only, deliberately not for real public hosting, before being
retired. See [ADR 0023](docs/adr/0023-retire-adr-0009-pitchfork-demo.md)
for the demo-vs-real-hosting distinction — it still holds.

**Effort:** S (research + decision) / M (actual setup)
**Priority:** P2
**Depends on:** digest-as-source-of-truth T5b (demo/proof deploy) proven

### A real resolved-dependency-graph boundary check — planning session

**What:** Run `/plan-eng-review` on replacing (or backstopping) the
`ls-lint` + `ast-grep` boundary **lint** with a check that validates the
allowed-edge set against a **resolved** dependency graph, not literal path
strings.

**Why:** the lint shipped in the restructure (T2a) is honestly scoped — it
catches literal path strings, relative climbs, and `source`/exec of a
literal. It does **not** catch a path assembled from variables,
`source "$x"` resolution, or cross-language task references (its `ast-grep`
rules are per-language; TOML/Pkl task refs are uncovered). A boundary
violation built from a variable passes the gate today.

**Candidates to evaluate:** a generated manifest validated by
`conftest`/OPA (Rego); `tofu graph` for the HCL layer; whether CUE or
Timoni (already in the stack) can express and validate the edge set; a
purpose-built resolver. Weigh each against "one more tool" — the lint may
be enough paired with review.

**Already covered (Plan B X1, ADR 0018):** the one hard tofu edge — no
`kubernetes_*` / `kubernetes_manifest` resource — is the `no-kubernetes-tf`
hk step (`tests/check-tf-boundary.sh`, a `git grep`). This session backstops
only that one; the rest of the HCL layer stays review-only.

**Context:** Codex 2nd-pass finding CX2, user decision CX1=A (ship the
scoped lint + documented limits + this deferred session).
`docs/designs/repo-structure.md` § Enforcement / Honest scope.

**Effort:** planning ~1 session; implementation unknown until the approach
is chosen.
**Priority:** P3
**Depends on:** the restructure landed (the lint is the thing being
backstopped).

### T7a-follow-up — rename `frontend-*` / `attestation-*` to `<tool>-<verb>` — P3

**Open — rename `frontend-*` / `attestation-*` to `<tool>-<verb>`** (P3,
own task). `frontend-build.sh` / `frontend-publish.sh` /
`attestation-sign.sh` / `attestation-verify.sh` use the concern name and
contradict the (unchanged, enforced) Scripts Policy. No single tool
drives them (tekton + oras + cue; cosign + oras + openbao) — the rename
needs thought, and it touches `mise.toml` tasks, ADRs, README, bats.
(`frontend-deploy.sh`/`frontend-serve.sh`, the other two originally named
here, are gone — ADR 0023 retired them, not renamed them.)

### `openbao-verify.bats`'s `online()` helper checks only one of two registries — P3

**Found 2026-09-14** while running `mise run check` for T8 (unrelated to it —
confirmed on clean `main`). `environments/local/scripts/tests/openbao-verify.bats`'s
`online()` helper checks only `ghcr.io` (the chart registry) reachability
before deciding whether to run the anti-rotation-guard cases live. The
script itself (`openbao-verify.sh`) ALSO needs `quay.io` (the image
registry) for its second `crane digest` check, and self-skips (exit 0,
no failure) if that one specific registry is unreachable — independent
of `ghcr.io`. When `quay.io` is down (confirmed live: 504/502 gateway
errors while `ghcr.io` answered fine) the bats `online()` check passes,
the test runs, the script hits its OWN internal skip on the `quay.io`
call before ever reaching the anti-rotation grep, and the test then
falsely reports the guard failed (it never ran) rather than skipping
cleanly like the script's own design intends ("a flapping registry does
not red `mise run check`" — true for the script, not for this test).

**Fix:** `online()` should check both `ghcr.io/openbao/charts/openbao:0.29.4`
and `quay.io/openbao/openbao:2.6.2` (or whatever `openbao-verify.sh`'s
`image_ref:image_tag` currently resolve to) before proceeding, matching
what the script itself actually needs to succeed past the render step.

**Priority:** P3 — not a real regression, a test-harness gap. Not fixed
here (out of scope for T8; flagged per repo-ownership discipline).

### R5 — OCI-bundle distribution of the `ci/` defs — deferred

**R5 (DEFERRED)** — OCI-bundle distribution of the `ci/` defs
(`tkn bundle push`, self-contained Pipeline + Task closure, `@sha256:`
resolver pins). This is ADR 0014's stated end state, recorded UNFINISHED —
per-run def pinning is unfinished until this ships. **Trigger:** a 2nd
`ci/` consumer, OR `environments/production/`. Until then a `PipelineRun`
uses whatever `ci-{tasks,pipelines}` last reconciled from `main` —
acceptable for a single-operator dev cluster, **not** a pin.

**Folded in from the old T8 scope (2026-09-14):** once the bundles exist,
sign them with a dedicated key
([ADR 0014](docs/adr/0014-tekton-defs-are-oci-bundles-in-ci.md)). Moved
here rather than staying in T8 because it was silently depending on this
item shipping first with no recorded trigger — the correct trigger is R5's
own, above, not T8's.

### T7d — production repoint — deferred

**T7d — production repoint (DEFERRED).** Trigger = `environments/production/`
exists (needs `cluster-k0sctl`, unbuilt). Nothing to repoint until then. With
R1 done, production's zot is HTTPS + the dev-CA pattern from day one
(production swaps the CA `issuerRef` for a real backend, leaves the leaves).
T7d = a `TODOS.md` checklist next to O4/O5, no estimate.

### Pin-drift guard: host `mise.toml` vs `ci/tasks/*` step images — P3

**What:** keep `trivy`/`oras`/`tkn` versions synced between the host toolchain
(`mise.toml`) and the Tekton Task step images (T7b2 introduces the second pin
site). **Why:** a scan running a different `trivy` than the linter is a
silent-wrong-result bug — the class the repo exists to prevent. **First step:**
**research common conventions** — renovate/dependabot grouped updates, a
generated lockfile both sides consume, running `mise` *inside* the Task images,
Tekton image refs as params from one manifest — then iterate + innovate, rather
than reflexively adding another `mise run check` step. Pins move ~quarterly.
**Depends on:** T7b2.

### Tekton Dashboard — P3, deferred

**What:** Install the read-only Tekton Dashboard on `orb start k8s` for
TaskRun/PipelineRun visibility during T7b+ development.

**Ceiling (deliberate):** local-only, accessed **only** via `kubectl
port-forward` — no Service exposure, no ingress. Image digest-pinned.

**Why:** faster than `tkn` CLI + `kubectl describe` when debugging pipeline
runs. Owner-requested, explicitly no rush.

**Prereq before it touches the k0s production cluster:** a
`CiliumNetworkPolicy` (ingress from the port-forward path only, egress to
kube-apiserver only) + a Kyverno least-privilege-RBAC exception for the
Dashboard's broad-read ClusterRole. The Dashboard ships **no auth** — an
unauthenticated endpoint on a cluster that also runs untrusted build steps
is a lateral-movement target without a network policy.

**Priority:** P3 · **Depends on:** T7a (Tekton installed). Blocked for
production on the Cilium + Kyverno module builds.

### T10 — VEX hardening — P3, post-T8

**What:** Promote the scan-clean-first posture to an enforced mechanism:
`.openvex.json` statement(s) → `vexctl attest` (signed via an OpenBao
Transit key, same custody as approval/provenance) → attached as an OCI
referrer → `mise run frontend:publish` re-runs `trivy image --vex <referrer>
--severity CRITICAL --exit-code 1` against the SBOM referrer before
accepting a digest (the ADR-0009 pitchfork path this named is retired,
ADR 0023 — `frontend:publish` is the only consume gate now).

**Why:** an unsigned, consume-unenforced VEX statement buys no present
enforcement benefit; this is where the benefit lands. `vexctl`
(`aqua:openvex/vexctl`) is already pinned.

**Priority:** P3 · **Depends on:** T8 (build-provenance signing infra —
reshaped 2026-09-14, no Chains involved).

### Publish a multi-arch image once a real amd64 consumer exists

**What:** Extend the `buildx` build from `--platform linux/arm64` to
`--platform linux/amd64,linux/arm64`, and update T5/T5b to handle the
resulting **index digest**: scan and runtime-smoke-test *both* child
manifests, merge those exact outputs mutable-tag-race-safe, then approve
the final index digest (not one `trivy image INDEX` call).

**Why:** Portability — a hiring manager pulling the image on an amd64 laptop
or cloud runner. Today every consumer in the design is arm64 (dev Mac,
OrbStack cluster, T5b's Docker-on-Mac deploy), so amd64 is speculative
build+evidence work against no target.

**Context:** `docs/adr/0008-arm64-only.md` chose arm64-only deliberately;
the index-digest cost makes multi-arch a real T5/T5b scope change, not a
one-flag switch.

**Effort:** M (build flag is trivial; the T5/T5b index-digest handling is
the real work)
**Priority:** P3
**Depends on:** an actual amd64 deploy or demo target; digest-as-source-of-
truth T5/T5b proven on arm64 first

### Kyverno ImageValidatingPolicy for real admission-time enforcement — production cluster

**Dev-cluster half already shipped:** Plan B K1 / ADR 0020 put one
`ImageValidatingPolicy` live on the OrbStack dev cluster, gating
`cv_frontend` at admission. This item is now specifically the
**production**-cluster instantiation of the same mechanism.

**What:** A Kyverno policy on the production cluster that rejects any image
digest lacking a validly-signed approval referrer at real k8s admission
time — not just a consume-side script check.

**Why:** Moves the trust boundary from "a script checks before you manually
run something" to actual in-cluster enforcement — the complete version of
this design's zero-trust claim, and resolves one of CLAUDE.md's own
long-deferred items ("Kyverno enforcement mechanics... design at Kyverno
module build time").

**Context:** `docs/adr/0003-tekton-pipelines-on-orbstack-k8s.md`'s rejected
Approach C — deferred because it coupled three previously-independent
concerns (the Tekton module set, `cluster-k0sctl`, Kyverno mechanics) into
one dependency chain. Only makes sense once `cluster-k0sctl`'s *production*
cluster exists (not the OrbStack dev cluster Phases 2-3 use) — building it
against the dev cluster would be enforcing policy on a throwaway
environment.

**Effort:** L
**Priority:** P3
**Depends on:** cluster-k0sctl module built, digest-as-source-of-truth
Phase 2-3 proven

### Remove `crane` from the stack entirely — planning session — P3

**What:** `crane`'s zot-facing use is gone (R1b-ii-c swapped `registry-seed.sh`
to `oras cp`); the one remaining call is `openbao-verify.sh`'s `crane digest`
against a public chart registry (quay.io/ghcr.io — real HTTPS, system trust,
unaffected by the CA-file gap). Investigate whether that call can move to
`oras` (or `helm show chart`/`helm pull --digest`, since it's specifically a
Helm OCI chart digest check) so `google/go-containerregistry` drops out of
`mise.toml` altogether — one fewer pinned tool, one fewer thing with its own
Go-toolchain/CA quirks to reason about.

**Why:** every pinned tool is a maintenance surface (CLAUDE.md § Tool
Boundaries — one job per tool); if `oras` already covers the one remaining
job, keeping `crane` around too is redundant coverage the repo's own
constraints call out as a smell, not a strict-overlap violation to ignore.

**Also fold in:** a broader look at where else a dedicated single-purpose
CLI could collapse into an already-pinned tool the same way — OpenBao's own
tooling surface (`bao` CLI vs. direct API calls the scripts already make in
places) is the other candidate worth the same question in the same session.

**First step:** confirm `oras`/`helm` can do a digest-only chart-pin check
without pulling the full chart (matching `openbao-verify.sh`'s current
cheap-check shape) before committing to the swap.

**Depends on:** R1b-ii-c (crane's zot use) landed. **Triggers with:** the
next chart-pin gate touch, or a dedicated tooling-consolidation session.

### Upgrade cosign signing to public trust (Fulcio/keyless or published key)

**What:** Move both cosign keys (approval, build provenance — T8, no
Chains) from
mechanically-required-only signing (OpenBao Transit-backed, unpublished)
to a publicly verifiable trust chain — Fulcio/keyless signing, or at
minimum a published public key with a real registration/verification story
a stranger could check.

**Why:** Closes the last gap between "a signature exists" and "a
Platform/SRE hiring-manager reviewer can independently verify who signed
this, without trusting the repo owner's say-so" — the actual CV-signal
payoff this whole design was built toward.

**Context:** Deferred throughout the design — `docs/designs/digest-as-source-
of-truth.md` § Constraints ("public-trust signing is deferred"). The
mechanical signing (OpenBao Transit, unpublished keys) is built and proven
first. cosign's keyless mode is a documented alternative for when this
lands.

**Effort:** M
**Priority:** P3
**Depends on:** digest-as-source-of-truth Phase 1-3 stable
