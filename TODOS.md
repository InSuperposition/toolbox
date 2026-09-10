# TODOS

## Debt

### Local OpenBao unseal-key storage — ✅ DONE (ADR 0010 + 0011)

Resolved on `feat/openbao-machine-global-and-gate`: one machine-global
pitchfork daemon that auto-unseals from a `0600` `seal.key` file; the root
token and recovery key are `0600` files too; `mise [env]` injects
`VAULT_TOKEN`; `fnox` + the keychain are removed from the stack entirely.
No memorized secret, no recurring manual step. `pitchfork.toml`-rewrite and
`fnox.toml`-rewrite hazards documented (F7/F8). `gh` token expiry is still
open — folded into "Auth + multi-member DX".

### Scripts-policy audit of the T5 / T5b shell — reduction pass — ✅ DONE

Round 1 (`feat/openbao-machine-global-and-gate`): `hk.pkl` + `mise run
check` gate (was missing entirely); `export-approval-pubkey.sh` deleted →
one-line mise task; `openbao-preflight.sh` advice trimmed; `bootstrap` /
`reset` simplified (no `fnox`, no `security`, atomic file writes).

Round 2 (this eng-reviewed reduction pass — 3 pushes):

Eng-reviewed (+ Codex outside voice), 3 pushes on `main`, plan
`~/.claude/plans/polymorphic-twirling-minsky.md`:

- **Push 1** (`ebdaf92`) — `attestation-verify.sh`: deleted the
  `case "$err" in` cosign-stderr classifier (a cosign bump would silently
  reclassify a trust failure). One terminal "attestation verification
  failed" line + cosign's own output to the log; cosign's
  `--type/--check-claims/--digest` call unchanged (Codex: don't
  re-implement it in jq). attestation-verify.bats 9→11.
- **Push 2** (`813509b`) — `attestation-sign.sh` §7:
  `cosign attest --no-upload --bundle` + `oras attach
  --disable-path-validation --format go-template --template '{{.digest}}'`
  → deterministic `ATT_DIGEST`; deleted the `oras discover` diff +
  predicate-match candidate loop (~35 lines, net −21). `oras attach` sets
  `artifactType` but not the `predicateType` annotation — nothing in-repo
  reads it (consumer decodes the DSSE layer; ADR 0006).
- **Push 3** — consistency only. `openbao-reset.sh` stale
  `bootstrap-openbao.sh` comments → `openbao-bootstrap.sh`.
  **Commit C (frontend readiness) was DROPPED:** the plan's premise
  ("redundant poll, move to config") is wrong — pitchfork 2.24's `ready_*`
  poll is UNBOUNDED (verified: a never-ready `ready_cmd` hangs `pitchfork
  restart` forever), and `pitchfork restart --delay 0` + no daemon
  readiness broke the happy-path [docker] deploy tests (container not
  observed serving within the poll window). Current state — `ready_port =
  44100` on the daemon + a 30s poll in `frontend-deploy.sh` — works and is
  tested. Revisit only if the cv_frontend crash actually hangs a deploy in
  practice (Remix likely binds the port then crashes on a request →
  `ready_port` passes → the poll reports "did NOT come ready", no hang).

**KEPT (rejected reductions):** `openbao-preflight.sh` (5-state floor,
reviewed 4c), `attestation-sign.sh` orchestration, `frontend-serve.sh` (the
`docker run &` + trap dance IS the documented-correct shape — pitchfork
`exec docker run` orphans the container), `openbao-{reset,snapshot}.sh`,
`check-coverage.sh`, the `sign_image`/`run_sign` 6-line overlap (`tests/lib`
can't name a concern — `boundary-testlib-concern-ref`), the `TOOLBOX_*`
seams.

### `openbao-bootstrap.sh` OpenBao-identity guard — ✅ DONE (fix/openbao-identity-guard)

**Was:** `openbao-bootstrap.sh` `bao status … '.initialized == true'`
treated ANY initialised `bao` on `$LISTEN` as ours → a foreign
`bao server` on `:8200`, or a stale per-worktree daemon
(`toolbox-sealed-8200-stale-worktree`), got the 2nd `tofu apply` + pubkey
export.

**Fix:** before skipping init on `initialized == true`, require
`$STATE_DIR/root.token` to authenticate against the running instance
(`bao token lookup`). Miss → `exit 1` naming the likely cause, with
`pitchfork list` / `ps aux | grep '[b]ao server'` hints. Negative-space:
no new state file, no `cluster_id` fingerprint — reuses `root.token`,
which must be valid for the rest of the script anyway. New bats case
(openbao-bootstrap.bats 8→9): garbage `root.token` post-init → exit 1, no
Transit provisioning.

## Infrastructure

### Repo restructure — strict ownership boundaries — ✅ DONE (P0–P5)

**What:** Apply the file-placement rule (`docs/designs/repo-structure.md`,
ADR 0012/0013) repo-wide in phased typed PRs. Each phase = one PR (P1 = up
to 4), `mise run check` green on its own.

Reviewed plan (eng review + 2 codex passes, `NO UNRESOLVED DECISIONS`):
`~/.claude/plans/repo-restructure-boundaries.md` — the authority for
per-task files, verification, and rationale. Summary here; do not
duplicate detail.

| task | phase | what | status |
|---|---|---|---|
| T1 | 0 | `repo-structure.md` + CLAUDE.md § File Placement + ADR 0012/0013 — no code | ✅ done |
| T2a | 1a | pin `ls-lint` (`aqua:loeffel-io/ls-lint`) + `ast-grep` (`aqua:ast-grep/ast-grep`); `.ls-lint.yml` + `sgconfig.yml` + `rules/boundary-*.yml` for the **current** tree; wire both into `hk.pkl` fast layer | ✅ done |
| T2b | 1b | `tests/lib/{scratch,registry}.bash`; per-`tests/`-dir `helper.bash` loader (F2 resolved simpler — no `setup_suite.bash` / `BATS_LIB_PATH`); `deploy/frontend/tests/` → `deploy/frontend/scripts/tests/` | ✅ done |
| T2c | 1c | `tests/check-coverage.sh` (disk vs `manifest.txt` vs `hk … --plan --json`) + `tests/check-coverage.bats` mutation test; `tofu-init` ordered prereq (`depends`) in `hk.pkl`; clean-checkout validation | ✅ done |
| T2d | 1d | `tests/lib/ports.bash`; OpenBao bats take a free port (was fixed :8397-8399); `run.sh`/`consume.sh` gain `TOOLBOX_FRONTEND_{HOST_PORT,CONTAINER}` seams (baked into `scratch_frontend`'s `pitchfork.toml` env); dropped `bootstrap.bats` machine-wide `pitchfork clean`; scoped `deploy.bats` teardown | ✅ done |
| T3 | 2 | OpenBao `git mv` → `environments/local/{openbao,scripts}/`, `source = "./openbao"` (label kept — `tofu plan` = No changes), `lib/openbao.sh` + `openbao-snapshot.sh` extracted, `hk` tofu globs widened to `environments/**`, `modules/README.md`, `.ls-lint.yml` `**/scripts/lib` override, openbao bats adopt `scratch_copy` + `pitchfork clean --daemon` | ✅ done |
| T4 | 3 | `openbao-*` mise tasks → `local:openbao:*` (+ new `local:openbao:stop`); every `mise run openbao-*` ref rewritten (scripts, bats, docs, ADRs, pitchfork.toml). `approve`/`consume`/`verify-approval`/`export-approval-pubkey` → `attestation:*`/`frontend:*` deferred to Phase 4 (renamed with their script moves). | ✅ done |
| T5a–d | 4 | **ONE PR** (commits 4a→4d) — extract `attestation/` (sign/verify/preflight/cue/pub + `lib/attestation.sh`); split `deploy/frontend/` (`frontend-deploy.sh` / `frontend-serve.sh` + `lib/frontend.sh`'s `TOOLBOX_ATTESTATION_VERIFY` seam, default resolved via the mise.toml marker — no lint exception); `openbao-preflight.bats` **5-state** + corrected static-seal advice (init check before seal check); `openbao-bootstrap.sh` calls `mise run attestation:export-pubkey` (drops the `REPO_ROOT` climb + both ast-grep exceptions). Real CI run 34127037520 green (21/21). | ✅ done |
| T6 | 5 | docs-accuracy sweep — `digest-as-source-of-truth.md` (paths, task names, the machine-global-daemon layout, 5-state preflight, the `TOOLBOX_ATTESTATION_VERIFY` seam, no-keychain honesty); ADRs 0004/0005/0006/0009/0011 name refs; `main.tf` comments (`openbao-bootstrap.sh`); link-check clean. | ✅ done |

**Phase 1b–1d carry-overs** (not blockers):

- ~~`environments/local/tests/*.bats` adopt `scratch_copy` in Phase 2~~ —
  done (Phase 2 moved the dir to `environments/local/scripts/tests/` and
  they now use `scratch_copy`).
- ~~`tests/lib/assert.bash` not created yet~~ — created in T9a
  (`file_mode()`, GNU+BSD `stat`), sourced by
  `environments/local/scripts/tests/helper.bash`. Other `[ "$status" -eq
  N ]` checks stay as-is.
- ~~**C4** (`attestation/` scratch + a default-`TOOLBOX_ATTESTATION_VERIFY`
  case)~~ — done in Phase 4b: `scratch_frontend` copies both `attestation/`
  + `deploy/frontend/` + a `mise.toml` marker, every scratch test runs on
  the un-overridden seam, and `frontend-serve.bats` has an explicit
  positive default-seam case.
- `frontend_isolation` names the container `toolbox-frontend-test-$$-<n>`;
  the real deploy still defaults to `toolbox-frontend` / host port 44100.
- ~~**Re-run the clean-checkout check after Phase 2** (C5)~~ — T9a's
  `.github/workflows/check.yml` runs `mise install && mise run check` on a
  fresh runner checkout every push/PR; run 34144986089 green covers this.
- `check-coverage.sh` cross-checks `hk`'s scheduled **count** of `.bats`
  files, not the exact filenames (hk's `--plan --json` gives `fileCount`,
  not a file list). A same-count swap (drop A, add B, no manifest edit)
  would pass the count check but fail the disk-vs-manifest diff, so it is
  still caught — just by view 2, not view 3.

**Lint exceptions — all cleared as of Phase 4d:**

- ~~`.ls-lint.yml` ignores `run.sh` / `approve.sh` / `consume.sh`~~ — gone
  (4a renamed `approve.sh`/`verify-approval.sh` → `attestation-*`; 4b
  renamed `run.sh`/`consume.sh` → `frontend-serve.sh`/`frontend-deploy.sh`).
  `.ls-lint.yml` has **no** `ignore:` entries for source files now.
- ~~`rules/boundary-shell-{deploy-ref,concern-climb}.yml` exclude
  `openbao-bootstrap.sh`~~ — gone (4d: it calls `mise run
  attestation:export-pubkey`, no `deploy/` ref, no `REPO_ROOT` climb).
  `boundary-shell-concern-climb.yml` still ignores `**/tests/**` (test
  fixtures legitimately reach across concerns); that is permanent, not an
  exception.
- **HCL not covered.** `ast-grep` ships no Terraform grammar, so the tofu
  unit's forbidden edges are not machine-checked. Folds into the deferred
  resolved-graph planning session below.

**Merge order:** all phases (P0–P5) landed on `main` (solo repo). Done.

**Effort:** ~1d human total (CC-assisted ~6h). **Priority:** P1.
**Depends on:** nothing.

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

**Context:** Codex 2nd-pass finding CX2, user decision CX1=A (ship the
scoped lint + documented limits + this deferred session).
`docs/designs/repo-structure.md` § Enforcement / Honest scope.

**Effort:** planning ~1 session; implementation unknown until the approach
is chosen.
**Priority:** P3
**Depends on:** the restructure landed (the lint is the thing being
backstopped).

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

### Auth + multi-member DX — DEFERRED, no trigger yet

**Status (2026-09-08):** Deferred, not scheduled. YAGNI — there is one
developer, the machine is the trust boundary (ADR 0011), and nothing open
(T7b included) needs this. An `/office-hours` pass on 2026-09-08 concluded
there is no design session to run until a trigger below fires. This entry
exists to record the trigger and the pre-picked direction so a future
session does not re-derive them.

**The two gaps — kept distinct, `auth` alone is ambiguous:**

| Principal | Authentication (which principal is acting) | Authorization (what it may do) |
|---|---|---|
| **Human approver** | `attestation-sign.sh` presents the **root token**; OpenBao authenticates the token, not a person. `approvedBy` is a typed string (`gh api user` / `$USER`), unverified. | Root token ⇒ every path. Wants a policy scoped to `transit/sign/approval-key` only. |
| **Pipeline pod** (T7b+) | T7a copies an operator `gh auth token` into a `docker-registry` Secret; the pod "is" whoever minted it. No workload identity. | That token carries the operator's full `gh` scopes. Wants push-one-repo / clone-two-repos and nothing wider. |

**Why it is safe to defer:** the zero-trust claim ("possession of the
private key is the access control") collapses today to "possession of one
`0600` file on one machine" — which ADR 0011 accepts as correct for a
single operator. The 2026-09-06 T5 eng review filed this as
known-deferred P2, not urgent. The only forcing function for the human gap
is a second approver.

**Reopen when ANY of:**
1. A second person needs to sign an approval verdict (the real trigger for
   the human gap).
2. The build/scan pipeline moves to a shared runner, a CI service account,
   or any host where a personal `gh` token is the wrong credential (the
   trigger for the pod gap) — note T7b on the local single-user OrbStack VM
   does **not** cross this line; T7a's interim `gh`-token Secret is fine
   there.
3. `zot` replaces GHCR (T7d) and needs its own identity model wired.
4. T8 (Tekton Chains) — narrower and already scoped: adds a
   `chains-provenance-key` Transit policy denying it `approval-key`.
   `environments/local/openbao/main.tf` already has the empty `policies`
   input for exactly this; T8 does not need this whole session.

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
  is unbuilt. SPIFFE/SPIRE is an innovation-token overspend for one VM.
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

### T7 Phase-2 (Tekton) — re-cut, planned 2026-09-08

**Planning done.** `/plan-eng-review` (2026-09-08, ×2) + Codex outside voice
re-cut the arc around a **composable `ci/` concern**. T7a plan:
`~/.claude/plans/t7a-buildkit-in-cluster-proof.md`. **T7b re-cut plan (2026-09-08):**
`~/.claude/plans/t7b-pipeline-recut.md`. Key decisions
([ADR 0014](docs/adr/0014-tekton-defs-are-oci-bundles-in-ci.md)):

- Builder = **BuildKit, daemonless, rootless** (`buildctl-daemonless.sh` in
  the TaskRun pod — no buildkitd Deployment/Service). Chosen over
  `docker buildx --driver=kubernetes` (heavier — manages a pod) and
  kaniko/buildah. Registry cache, not a PVC. **KEDA scale-to-zero dropped** —
  no standing builder to scale.
- Reusable Tekton defs live in a new top-level **`ci/`** concern, **not
  `modules/`**. Per-consumer instantiation lives in `deploy/<consumer>/`.
  **The distribution mechanism** (`tkn bundle push` + bundles-resolver vs
  Flux `OCIRepository`) is **decided in the T7c pre-plan**, not T7b — whichever
  reconciler T7c picks owns the digest pin + cosign-signing the defs
  (2026-09-08 eng review). ADR 0014's intent (digest-pinned, cosign-signable
  defs, version = digest) stands; only the push mechanism is deferred.
- Tekton controller + `zot` installs are `environments/local/` concerns
  (interim `mise` task now, Flux `OCIRepository`/`Kustomization` in T7c), not `ci/`.
- byte-level build reproducibility → **T8** (with Chains provenance).
- `deploy/frontend/Dockerfile` line 1 `# syntax=` **pinned by digest** in T7a
  (Codex: unpinned frontend = input-trust hole, distinct from timestamp
  reproducibility).
- **`deploy/frontend/pipelinerun.cue`** renders the on-demand `PipelineRun`
  (T7b3, DONE) — **plain CUE + `cue export -t`, not a Timoni module** (a
  PipelineRun is fire-and-forget; Timoni's footprint only pays off for a
  reconciled Instance). The first real Timoni module is the `cv_frontend` **app
  deployment**, during/after T7c.

**T7a — rootless BuildKit feasibility spike, then the `ci/` concern.**
_Prove first._ **Step 1 ✓ PASSED 2026-09-08** — daemonless rootless BuildKit
built `cv_frontend` in-cluster (orb k8s v1.35.6, Tekton Pipelines v1.6.0)
and pushed `linux/arm64` by digest to GHCR; `docker pull` of that digest
verified. Minimum pod posture: `runAsUser 1000`, `seccomp: Unconfined`,
`allowPrivilegeEscalation: true` (file-cap `newuidmap`), `caps drop [ALL]
add [SETUID,SETGID]`, `BUILDKITD_FLAGS=--oci-worker-no-process-sandbox`
(required). NOT privileged, no `SYS_ADMIN`; `hostUsers: false` unavailable
(Tekton `podTemplate` has no such field). Full result + proven Task config
in `~/.claude/plans/t7a-buildkit-in-cluster-proof.md` § "Step 1 — SPIKE
RESULT". Tekton v1.6.0 kept for Step 2.
**Step 2 ✓ DONE** — `ci/` concern extracted: `ci/tasks/buildkit-build.yaml`
(spike-proven posture, parameterised, consumer-agnostic, **one step —
pinned `command`/`args`, no `script:` block**; pushes under a per-run tag,
`tekton-taskrun.sh` does `oras resolve` for the digest + the
`ci_is_strict_digest` guard) + `ci/runtime/namespace.yaml` (no RBAC,
`automountServiceAccountToken: false`, PSA `privileged`) +
`ci/scripts/{tekton-taskrun,kubeconform-scan,chainsaw-test}.sh` + `lib/ci.sh` +
20 bats cases + a `[k8s]`-gated chainsaw scenario (webhook accepts the Task,
no `script:` field, posture-drift guard) + `rules/boundary-ci.yml` +
`hk.pkl` kubeconform (fast) / chainsaw (heavy) steps + `mise` tasks
`ci:taskrun` & `local:tekton:install` (pinned Tekton v1.6.0) + Tekton v1
CRD schema vendored at `ci/tests/crd-schemas/`.
[ADR 0014](docs/adr/0014-tekton-defs-are-oci-bundles-in-ci.md).
_Carry-over:_ machine-global `orb-k8s` pitchfork daemon — the stanza is
**documented** in `environments/local/README.md` § Tekton; auto-registration
is deferred to a future `local:bootstrap` aggregate (P2). The full
build→push chainsaw assertions need a registry cred — folded into T7b's
credential-light `git-clone` Task. A proper Tekton `IMAGE_DIGEST` result is
deferred to T7b too (see below). Answered: rootless viability, in-cluster
GHCR push auth, pod privilege posture.

**T7a-follow-up — `ci/` concern script hygiene.** _P2._ From the PR #9
review; branch `ci/t7a-followup-hygiene`.
- ✅ **Renamed `ci/scripts/*.sh` to `<tool>-<verb>`** (`f492f5c` + `dffef3f`):
  `ci-taskrun` → `tekton-taskrun`, `ci-kubeconform` → `kubeconform-scan`,
  `ci-chainsaw` → `chainsaw-test`; `lib/ci.sh` stays. Full ref sweep + the
  per-run cluster-object prefix.
- ✅ **Recurrence lint** (`69a2cff`): `rules/boundary-no-embedded-shell.yml`
  (`ast-grep`, `language: yaml`) fails `mise run check` on a `script:`
  block under `ci/tasks|runtime|pipelines/`.
- ✅ **bats for `tekton-taskrun.sh`** (`b67fa34`): `common_prefix`
  (grandparent / component boundary / identical dirs / `STAGE_ROOT == /`),
  `cleanup` (`--teardown` scoped to this run's objects, never the
  namespace; `--keep` deletes nothing), `DCJ_FILE` mode 600.
- ❌ **actionlint + check.yml `run:` tidy** — dropped. GitHub Actions is
  not the source of truth (Tekton is); no new tooling for the transitional
  workflows.
- ➡️ **Extract the `tekton-taskrun.sh` PV/PVC + TaskRun heredocs** — moved
  to **T7b**. Shell must never author YAML (hard rule); T7b's staging
  rewrite (git-clone Task + `PipelineRun`) replaces the heredocs with
  committed Tekton YAML anyway, so fixing them separately first is wasted.
- **Open — rename `frontend-*` / `attestation-*` to `<tool>-<verb>`** (P3,
  own task). `frontend-deploy.sh` / `frontend-serve.sh` /
  `attestation-sign.sh` / `attestation-verify.sh` use the concern name and
  now contradict the (unchanged, enforced) Scripts Policy. No single tool
  drives them (cosign + oras + openbao; docker + the verify seam) — the
  rename needs thought, and it touches `mise.toml` tasks, `pitchfork.toml`,
  ADRs, README, bats.

**T7b — the working in-cluster Pipeline (re-cut 2026-09-08).**
Full plan + eng-review report: `~/.claude/plans/t7b-pipeline-recut.md`. Scope
is **the working Pipeline + an end-to-end demo only** — the OCI-bundle
distribution and `build-cv-frontend.yml` retirement are **deferred to a phase
after the T7c pre-plan** (that pre-plan decides the reconciler, which owns the
pin mechanism). Sub-phased, each ships + tests on its own:

- **T7b0** — interim **zot** on orb (pulled forward from T7d). ✅ **DONE.**
  `environments/local/zot/zot.yaml` (one multi-doc manifest, image pinned by
  digest `sha256:56230c…`, credential-free, **GC off** which subsumes
  `deleteUntagged: false`) + `mise run local:zot:{install,wait,uninstall}` +
  `zot-manifests.bats` (7) + a `kubeconform-zot` hk step + `environments/local/README.md`
  § zot. **Live verify passed 2026-09-08** on `orb start k8s` (v1.35.6): host
  NodePort reach `localhost:30500/v2/` → HTTP 200; host + in-cluster
  (`zot.zot.svc.cluster.local:5000`) `oras` push/pull round-trips; native OCI 1.1
  Referrers (`oras discover` tree); exposure is the NodePort only (no
  Ingress/LoadBalancer). Threat model: single-user VM, all cluster writers
  trusted; the P2 "zot registry auth" TODO opens real auth. **zot left running**
  for T7b1.
- **T7b1** — ✅ **DONE.** `ci/tasks/git-clone.yaml` (blobless shallow clone at a
  pinned SHA, anonymous; reuses the pinned `moby/buildkit:rootless` image — it
  ships `git`, so ONE image digest for the whole pipeline; steps run as root — the
  OrbStack `local-path` PVC is not group-writable under `fsGroup`, verified) +
  `buildkit-build.yaml` rewired (drop `TAG` + `dockerconfig` workspace + the `gh`
  Secret; push `$(IMAGE):$(APP_REVISION)` to zot, `registry.insecure=true`; **no
  Tekton result**) + `ci/pipelines/build-scan-approve.yaml` (`clone-app →
  clone-defs → build`, one `volumeClaimTemplate` workspace, subPath binding) +
  `ci/tests/crd-schemas/pipeline_v1.json` + `ci/tests/build-pipeline/chainsaw-test.yaml`
  + `ci/README.md` § Workspaces + **deleted `tekton-taskrun.sh` + `ci:taskrun` +
  its 18 bats + the two heredocs**.
  **Live-verified 2026-09-08** on `orb start k8s`: `clone-app` + `clone-defs`
  Succeeded (`cv_frontend@db174d91`, `toolbox@3210363` into `shared/app` +
  `shared/defs`); the `build` step mounted both workspaces, loaded the Dockerfile
  from `shared/defs/deploy/frontend/`, and buildkit began solving with the
  spike-proven posture — then hit **docker.io unreachable over IPv6** fetching the
  `# syntax=docker/dockerfile:1@sha256:` frontend (environmental egress, same as
  the T7a spike needed a network day). chainsaw green (webhook + no-`script:` +
  posture + DAG).
- **T7b1-followup — hermetic build (deterministic; prereq for T7b2+)** — P1,
  **DONE 2026-09-08** (see § Status below).
  Investigation 2026-09-08 (`/investigate`): the intermittent `build` failure is
  **not** our defs. This OrbStack cluster gives pods a working `AF_INET6` stack +
  AAAA DNS but **no routable IPv6 egress** (node's only v6 is the non-routable
  ULA `fd07:b51a:cc66::2`); CoreDNS `loadbalance` shuffles the A/AAAA answer, so
  any Go registry client (buildkit/containerd remotes, **and zot's own
  `regclient`** — both verified) can pick an unreachable AAAA and hard-fail
  `connect: network is unreachable`. ~50% per external image fetch. A separate
  ~10% `git-clone` failure is `Could not resolve host: github.com (Timeout while
  contacting DNS servers)` — the OrbStack DNS proxy timing out.
  **Fix (chosen — Z2 + N1 + N4). DONE — see § Status below.**
  - **Z2 — seed zot + buildkit mirror.** `mise run frontend:seed` =
    `ci/scripts/registry-seed.sh deploy/frontend/Dockerfile` — `crane copy`
    (`crane` now pinned in `mise.toml`) every `# syntax=` + `FROM …@sha256:`
    ref **read straight from the Dockerfile at run time** into the T7b0 zot
    (no committed seed-manifest → no drift possible; the script is the single
    reader). Runs on the host, where IPv4 works. The `build` Task mounts the
    `buildkitd-config` workspace (`ci/runtime/buildkitd-mirror.yaml`, a
    ConfigMap) at `/cfg` and adds `--config /cfg/buildkitd.toml` to
    `BUILDKITD_FLAGS`; that file mirrors `docker.io` + `gcr.io` →
    `zot.zot.svc.cluster.local:5000`. buildkit then never contacts
    docker.io/gcr.io — **build-time egress shrinks to zot only** (security
    win). Rejected: zot `onDemand` sync (its `regclient` inherits the same
    IPv6 bug + zot #3795 docker.io-auth + #2584 tag@digest); Dockerfile
    `FROM` rewrites (couples the app Dockerfile to infra). The seed script is
    consumer-agnostic (Dockerfile is an arg); only the `frontend:seed` mise
    task binds the consumer path, same as `frontend:deploy`.
  - **N1 — one-shot privileged `disable-ipv6` step** first in both `git-clone`
    and `buildkit-build` (a Tekton step, not an initContainer — steps share
    the pod netns and run in order, so step 0 setting `sysctl -w
    net.ipv6.conf.{all,default,lo}.disable_ipv6=1` covers every later step).
    Removes the pod's v6 addrs, **DNS/AAAA untouched**, every dialer then uses
    v4. The `ci` ns is already PSA `privileged`; the build/clone work steps
    stay rootless — `disable-ipv6` is the only privileged container, asserted
    by the chainsaw test. Kept even with the mirror bound (belt + suspenders,
    and covers the mirror ever being unbound). Rejected: `no-aaaa` dnsConfig
    (changes resolution semantics — kept as the documented rollback); CoreDNS
    AAAA suppression (cluster-wide); `hostAliases` (Cloudflare/AWS IPs rotate).
  - **N4 — `retries: 2` on `clone-app` + `clone-defs`** in the Pipeline — the
    only lever for the DNS-timeout mode (N1 doesn't touch it); the failure is
    fast (~6s) so cheap. The build has no external egress left to retry.
  - **Not viable:** seeding the `moby/buildkit` step image into zot — the
    OrbStack kubelet refuses http zot (`http: server gave HTTP response to HTTPS
    client`). That pod image stays a docker.io pull; it is node-cached after
    first pull and resolves via `registry-1.docker.io` (A-heavy) — low one-time
    risk, accepted.
  - **Durable:** the Cilium planning session (this file) settles single- vs
    dual-stack; a v4-only Cilium datapath makes N1 unnecessary. Do not
    pre-commit.
  - **Status — DONE (2026-09-08, PR #15 branch).** `ci/runtime/buildkitd-mirror.yaml`
    (ConfigMap), `ci/scripts/registry-seed.sh` + `frontend:seed` task + `crane`
    pin, `disable-ipv6` step 0 on `git-clone` + `buildkit-build`,
    `buildkitd-config` workspace on the build Task + Pipeline,
    `retries: 2` on `clone-app`/`clone-defs`. `registry-seed.bats` (6 cases,
    manifest updated). chainsaw updated: step counts 3/2, the new
    `git-clone-only-the-sysctl-step-is-privileged` step, `buildkitd-config` in
    `pipeline-shape`. **Live: `mise run frontend:seed` populated zot (3 base
    images, digests preserved); `build-scan-approve` ran 3/3 Succeeded with
    the new specs** — `disable-ipv6` step logged `net.ipv6.conf.*.disable_ipv6
    = 1` on both build + clone pods, buildkit resolved all three `FROM` refs
    from the mirror in 0.0s (no external egress), zero `network is
    unreachable`. `mise run check` green. Docs swept (`ci/README.md` §
    Deterministic builds on OrbStack, `repo-structure.md`,
    `digest-as-source-of-truth.md`, `deploy/frontend/README.md`).
- **T7b2 — DONE 2026-09-08 (branch `t7b2-scan-attach`).** `ci/tasks/scan-attach.yaml`
  — one Task, 5 steps, pinned `command`/`args`, no `script:`:
  `disable-ipv6` (step 0 — trivy's vuln-DB pull is external, `/investigate`
  option A, "keep it simple for now") → `trivy image --format json` →
  `trivy image --format cyclonedx --skip-db-update` (native SBOM, keeps CVE
  ratings; shared `--cache-dir` on the workspace → **one DB pull**) →
  `oras attach` `application/vnd.trivy.report+json` →
  `oras attach` `application/vnd.cyclonedx+json`. Never blocks (no
  `--exit-code` — the CRITICAL gate is T7b3). `TRIVY_INSECURE` /
  `oras --plain-http=` carry `$(REGISTRY_INSECURE)`. Wired `runAfter: [build]`
  in `build-scan-approve.yaml` (`shared` workspace). Images pinned by digest
  (`aquasec/trivy:0.74.0`, `ghcr.io/oras-project/oras:v1.3.4`); `disable-ipv6`
  reuses the node-cached `moby/buildkit:rootless`. chainsaw updated (webhook
  accepts 4 defs, `scan-attach` 5 steps / no `script:`,
  `scan-attach-only-the-sysctl-step-is-privileged`, DAG adds `scan-attach`).
  Docs swept. **Cilium note updated:** 3rd `disable-ipv6` Task + a newly
  observed gap (step 0's sysctl doesn't reach buildkit's rootless build-exec
  netns — `npm ci` still hung once in ~4 runs) — a 4th Task, or k0s replacing
  OrbStack, is the trigger to make the Cilium datapath call.
  **Live: `build-scan-approve` ran 2/2 Succeeded** (1 earlier attempt killed
  after `npm ci` hung ~4m — the build-netns gap above). scan-attach's 5 steps
  all `Completed/0`; `oras discover localhost:30500/cv-frontend:db174d91`
  shows both referrers on `sha256:7bda3c3e…` —
  `application/vnd.trivy.report+json` + `application/vnd.cyclonedx+json`.
  `mise run check` green.
- **T7b3 — DONE 2026-09-09 (branch `t7b3-gate-timoni`).** Plan
  `~/.claude/plans/t7b3-gate-cue-render.md` (ENG CLEARED, 9 Codex findings
  folded). Shipped:
  - `ci/tasks/gate.yaml` — one step,
    `trivy convert --scanners=vuln --exit-code=2 --severity=CRITICAL --format=table scan.json`,
    reads the same `scan.json` `scan-attach` attached. **`--exit-code=2`, not 1**
    (plan A4 correction): trivy returns 1 for a match AND an internal error, so 2
    marks the CRITICAL verdict and 1 stays "gate errored". No `disable-ipv6` /
    privileged step — reads a local file. Wired `runAfter: [scan-attach]`.
  - `deploy/frontend/pipelinerun.cue` — **plain CUE, not a Timoni module**
    (plan D1): a PipelineRun is fire-and-forget, so Timoni's module + bundle +
    ~1.3 MB vendored `cue.mod` footprint doesn't pay off. `_rev` / `_defsRev`
    are hex-regex `@tag` injection points → `cue export` fails closed on a
    missing / non-hex value. One place holds both registry hostnames.
  - `deploy/frontend/scripts/frontend-build.sh` (`mise run frontend:build`) —
    preflight (context / Pipeline+gate / buildkitd CM / zot / `frontend:seed`) →
    `cue export -t` → `kubectl create` (namespaced `ci`, 15m timeout) →
    poll `.status.conditions[Succeeded]` off `Unknown` (client bound ~16m) →
    success: `oras resolve` + `frontend_strict_digest` (exit 5 on non-canonical),
    print this run's scan-report referrer digest, delete the run, print the
    `attestation:sign` line; failure: keep the run, classify by the `gate` step's
    exitCode (2 = loud CRITICAL box, 1 = "gate ERRORED not a verdict", else a
    task failed before the gate). `lib/frontend.sh` gained `frontend_kube` /
    `frontend_tkn` (context + `-n ci` pinned), `frontend_strict_digest`,
    `frontend_host_image`.
  - chainsaw: accepts the 5 defs, `gate` 1 step / no `script:` / unprivileged,
    DAG gains `gate`; **G1** — standalone `gate` TaskRun vs
    `fixtures/scan-{critical,clean,malformed}.yaml` asserting the step exitCode
    (2 / 0 / 1). Ran live green.
  - `ci/tests/crd-schemas/pipelinerun_v1.json` vendored; `frontend-build.bats`
    (24 cases) renders the real cue file + kubeconforms it.
  - **First real Timoni module = the `cv_frontend` app deployment**, authored
    during/after T7c once the Flux reconciliation model + ADR 0009 (pitchfork vs
    k8s) are settled. The build/clone Task `podTemplate` (the `disable-ipv6`
    step + `buildkitd.toml` workspace) stays plain committed YAML under `ci/` —
    it is **not** Timoni-rendered (superseded: the earlier "Timoni renders the
    podTemplate" note assumed the deploy/frontend module would exist at T7b3).
  - **End-to-end demo — RUN 2026-09-09 (live, orb k8s).**
    `mise run frontend:build -- db174d91` → the full DAG ran in-cluster
    (`clone-app → clone-defs → build → scan-attach → gate`, all Succeeded, gate
    3s), `frontend-build.sh` resolved `sha256:15f93475…`, printed this run's
    scan-report referrer `sha256:6709e3b2…`, deleted the run, printed the
    `attestation:sign` line, exit 0. `mise run attestation:sign` then signed it
    (attestation `sha256:35df3a31…`) — its evidence summary shows the **same**
    scan-report referrer `sha256:6709e3b2…`, so the build → sign evidence chain
    is intact (A5). **Failure path:** `mise run frontend:build --
    0000…0000` (non-existent SHA) → clone-app Failed → "PipelineRun … failed
    (Failed) before the gate ran", run KEPT with inspect commands, exit 1.
    `frontend:deploy` not re-run here — unchanged since T5b (live sign→verify
    round-trip already proven), and `cv_frontend`'s Remix v3
    `IMPORT_OUTSIDE_FILE_MAP` crash is an honest PASS of the mechanism (ADR
    0009). The gate's CRITICAL-block path is proven by chainsaw G1 (exitCode 2 →
    TaskRun Failed) + `frontend-build.bats` (exitCode 2 → loud override box).
  - **P3 follow-ups opened by this PR** (see § "T7b3 P3 follow-ups" below):
    the exact scan-referrer digest threaded through `attestation:sign` →
    `frontend:deploy` (evidence integrity, Codex #4); `frontend-deploy.sh`
    readiness tightened to HTTP 2xx + expected body (Codex #8).

**The digest is never a Tekton result** — tasks address the image by
`$(IMAGE):$(APP_REVISION)`, ordering is `runAfter`, and `oras resolve` produces
the immutable digest once at the operator boundary (the only value-consumer,
`attestation:sign`, runs outside the pipeline). This removes an extract script, a
`results:` block, `--metadata-file` choreography, and `enable-api-fields: alpha`.
ADR 0001 holds — the signed chain still pins the digest.

Effort: ~5–6 days across T7b0–T7b3 (T7a's "simple" bits each ran long).

**T7b3 P3 follow-ups** (opened by the T7b3 eng + Codex review, not blocking):

- **Exact scan-referrer digest through the sign → deploy chain** — P3. Today
  `attestation-sign.sh` picks the `last`-of-type `vnd.trivy.report+json`
  referrer; on a byte-identical rebuild (same digest) several can co-exist, so
  the pick is arbitrary. `frontend-build.sh` mitigates by printing this run's
  referrer digest for the operator to eyeball. Full fix: a new positional arg
  threaded `attestation:sign` → predicate `scanReportRef` → `frontend:deploy`.
  Touches the signer's signature + `frontend-deploy.sh` — its own PR. (Codex #4,
  reclassified **evidence integrity**, not auth.)
- **Tighten `frontend-deploy.sh` readiness** — P3. `frontend-deploy.sh:~67`
  accepts any non-`000` HTTP code as "serving". D6 keeps the T5b stance (a
  `cv_frontend` runtime crash is an honest PASS of the *mechanism*); tightening
  to HTTP 2xx + an expected body is a separate change to the consume seam.
  (Codex #8 original.)

**T7c — local Flux.** Pre-plan DONE (`~/.claude/plans/t7c-substrate-ordering.md`,
ADR 0015): `GitRepository` + plain YAML, per-path `kustomization.yaml`
inventories, Flux precedes the in-cluster OpenBao move, Crossplane not
sequenced. **Increments 0/1a/1b/2 SHIPPED** (PRs #18–#21): checksum-gated
Tekton install (the *controller* stays on `tekton-install.sh`, a named Flux
prerequisite) → digest-pinned self-managing flux-operator + `FluxInstance` +
chainsaw harness → Flux reconciles `zot` + `ci/{runtime,tasks,pipelines}` from
`main`. The build *run* stays operator-triggered (`frontend-build.sh`), **not**
Flux-reconciled — Pipelines-as-Code is the eventual git-event trigger, still
deferred.
_Remaining T7c:_ **Increment 4 — in-cluster OpenBao.** SHIPPED
([ADR 0016](docs/adr/0016-local-openbao-in-cluster-statefulset.md)):
`environments/local/openbao/` is a tofu-owned raft StatefulSet — Phase-A
`helm_release`, the `openbao-bootstrap.sh` bridge (source selection,
key-preserving `raft snapshot restore -force`, `approval-key` never
rotated), Phase-C `vault_*` (`sops` AES key + `flux_sops` k8s-auth role).
The host `pitchfork` daemon is retired. `/plan-eng-review` (2026-09-10)
split the rest into **Plan B** and **T-DR** (separate sections below). T8
(Tekton Chains provenance) is now unblocked — the in-cluster OpenBao serves
pods over TLS. Plan:
`~/.claude/plans/t7c-increment4-in-cluster-openbao.md` § "ENG REVIEW — PLAN
SPLIT".
_Observability (from the CI-log-visibility review):_ persist **failed-step
logs beyond `tkn taskrun logs`** via **Tekton Results** (needs log-collection +
a durable-storage backend, not just the API). **Not** Tekton Chains. Acceptance
test: a failed step's logs are retrievable *after* the TaskRun + Pod are
deleted. Mirrors the GHA-side fix (`check.yml` uploads
`$HK_STATE_DIR/{output.log,hk.log}`).
_Flux scope note (from `/investigate` 2026-09-08):_ Flux reconciles the
T7b1-followup `ci/runtime/buildkitd-mirror.yaml` ConfigMap (done, Increment 2).
The host seed (`mise run frontend:seed` → `ci/scripts/registry-seed.sh`) stays
a host step for now (it needs host IPv4 egress); moving it in-cluster as a Job
that re-runs on a `deploy/frontend/Dockerfile` `FROM`-digest change is still
open. Once Cilium's datapath is settled (Cilium planning session), revisit
whether the seed + mirror is still load-bearing or just an optimization.

**T7c/T7d distribution phase (was T7b4/T7b5).**
`ci/pipelines/*` + `ci/tasks/*` distributed by the chosen mechanism (`tkn bundle
push` → digest, or `flux push artifact` → `OCIRepository` digest), `@sha256:`
pinned in `deploy/frontend/`, cosign-signed; then **delete
`.github/workflows/build-cv-frontend.yml`** once build + evidence + approval +
consumption are demonstrated in-cluster end to end (T7b3 builds the chain; its
end-to-end demo closes it — this phase adds pinned distribution, retires GHA). **Do
not carry `build-cv-frontend.yml`'s embedded `run:` shell** (`:48` `tr`
lowercase, `:98` digest-extract + `case` guard) into anything — extract to a
tested script or delete with the workflow.

**T7d — production repoint.** The local zot is already Flux-reconciled
(`environments/local/flux/zot-sync.yaml`, Increment 1a). The eventual
`environments/production/` gets a zot with a real backup policy (the local
zot's disaster path is rebuild → re-approve → re-pin — acceptable for dev, not
prod). Effort: ~1d.

**Priority:** P2 · **Depends on:** ~~T5 + T5b~~ done. **T7b0–T7b3** ✓ →
**T7c pre-plan + Increments 0/1a/1b/2** ✓ → Increment 4+ (in-cluster OpenBao) +
the distribution phase + T7d.

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

### Plan B — Timoni + Kyverno + Crossplane boundary — P2, ENG CLEARED 2026-09-10

**What:** the deferred half of the T7c Increment 4 replan, re-scoped by
`/plan-eng-review` 2026-09-10 (Step 0 complexity trigger, then a scope cut,
then Kyverno added for correct ordering). Full reviewed plan + 12
implementation tasks: `~/.claude/plans/plan-b-timoni-kyverno-crossplane.md`
(seed: `~/.claude/plans/t7c-increment4-in-cluster-openbao.md` §§ REPLAN v2 /
CODEX REVIEW 2026-09-10).

**Ship order: `M1 → X1 → K1 → M3`.** Each = 1 PR = 1 squash commit.

- **M1** — author `deploy/frontend/timoni/` (CUE module for the `cv_frontend`
  k8s manifests — a build input, not a `modules/` entry). `#Config.image`
  carries the full `@sha256:[0-9a-f]{64}$` digest constraint + a negative
  fixture. hk step = inline `timoni mod vet cv-frontend ./deploy/frontend/timoni`
  — **no kubeconform** (`timoni mod vet` already validates against k8s CUE
  schemas; a 2nd validator for one concern is forbidden). **ADR 0019** —
  amends ADR 0009 (routes the demo into the cluster *as well*; pitchfork
  container retained) and **must state the concrete capability Timoni adds
  over the plain-CUE path** (typed multi-object `#Config`, semver'd module
  artifact, reproducible build) or that is the signal to drop it.
- **X1** — **ADR 0018**: the in-cluster pipeline is **render (Timoni/CUE) →
  reconcile (Flux) → enforce at admission (Kyverno) → provision
  consumer-declared backing infra (Crossplane, if ever activated)** — these
  are *stages*, not rivals; one owner per object per stage. Flux + Timoni
  **compose**, they are not alternatives. tofu `kubernetes_*` /
  `kubernetes_manifest` **banned** — enforced by a new
  `rules/boundary-no-kubernetes-tf.yml` ast-grep rule (needs an HCL-pattern
  spike + `**/*.tf` added to the `["ast-grep"]` hk glob + an `ast-grep test`
  step — none are free). The per-consumer namespace bundle stays Flux
  plain-YAML indefinitely. `XConsumerEnvelope` / XE1 **dropped**.
- **K1** — install Kyverno via Flux (HelmRelease + OCIRepository digest pin,
  `spec.verify` if the chart is keyless) + one **`ImageValidatingPolicy`**
  scoped to ns `frontend` that checks the cosign approval **attestation**
  against `attestation/cosign-approval.pub` (via `configMapGenerator`, not
  inlined). The policy must preserve the **ADR-0006 contract**: verify the
  in-toto predicate type + a **verdict-approved** predicate (a signed
  *rejection* is still signed) + the subject digest. Split-Kustomization
  pattern (`kyverno-policy` CR, `retryInterval` short) per the
  `toolbox-flux-kustomization-unknown-crd-deadlock` learning. **ADR 0020** —
  narrows the "production cluster only" deferral below: the
  ImageValidatingPolicy runs on the dev *reference* cluster (consistent with
  Flux/OpenBao/cert-manager/Tekton already there); the `ci`-namespace
  privilege-scoping policies stay deferred.
  **FEASIBILITY RISK:** [kyverno#16435](https://github.com/kyverno/kyverno/issues/16435)
  — Kyverno 1.19.0 SIGSEGVs on **keyed** cosign verification of
  **OCI-referrer bundle-format** attestations with tlog on. toolbox's
  attestations are exactly that shape. K1's build **must** pin a fixed
  version and live-spike the keyed + referrer + `--insecure-ignore-tlog`
  path, proving semantic equivalence to `attestation-verify.sh`
  (selected-approval / selected-rejection / wrong-subject / malformed).
- **M3** — deliver + deploy. Publish is a **Tekton Task**
  (`ci/tasks/timoni-publish.yaml`, `command`+`args`, no `script:`),
  workspace-shared, ordered **verify → render (`timoni build cv-frontend`) →
  publish (`flux push --output json` for the digest)**. Three distinct
  digests — image `D_img`, approval-attestation `D_att`, manifest-artifact
  `D_man` — named + bound in the plan; the git pin promotion is a reviewed
  human step, never auto-committed. `environments/local/flux/frontend.yaml` =
  `OCIRepository` (digest-only, no `spec.verify`) + `frontend-ns`
  Kustomization + `frontend` Kustomization
  **`dependsOn: [frontend-ns, kyverno-policy]`** (runtime order ≠ ship
  order — the workload must not reconcile before K1's webhook), **`wait:
  false`** (the app has a known boot crash — `wait: true` would block
  Kustomization-Ready forever). `chainsaw-frontend` asserts **delivery**
  (`.image == D_img`, container **started** not just Scheduled, policy
  **evaluated** via PolicyReport), **not** HTTP-200. One-line notes on ADRs
  0002/0005/0006 (approval contract preserved) + 0009/0012.

**Deferred (own triggers):**

| Item | Trigger |
|---|---|
| **O4 / O5** — extract `modules/secret-openbao/` (`moved` blocks — `deletion_allowed=false` on `sops`/`extra` keys makes `tofu destroy` fail partway) + `ha` / `awskms`\|`transit` unseal / `snapshot_schedule` / `tls_issuer` presets. **ADR 0017**. | `environments/production/openbao/` becomes real planned work (the true 2nd consumer — one consumer is not a module, `modules/README.md`). ADR 0012 stands until then. O4 planning also picks up a dedicated OpenBao Transit `manifest-signing` key for the M3 artifact. |
| **Crossplane install** (core + `provider-*` + a Composition + its own ADR) | a consumer declares backing infra it does not own (bucket / DB / queue / DNS as a CR) — **not** a directory count. |
| **G1** — Flux SOPS (`--sops-vault-configmap` + ConfigMap + `spec.decryption`) | a named secret needs SOPS decryption. Plan A's Phase C left the OpenBao side (`sops` key, `flux_sops` role) ready. |
| **Manifest authorization** (Codex #7) — scoped RBAC for the `frontend` kustomize-controller SA + a defined rendered-manifest review path (image approval ≠ authz of the manifests around it) | own review/session. |
| **Kyverno `ci`-namespace privilege policies** (PSA scalpel, build-pod securityContext) | `cluster-k0sctl` built + the Cilium planning session done. |
| **`chainsaw-frontend` HTTP-200 assertion** | the cv_frontend Remix v3 boot crash is fixed (cv_frontend repo). |

**Depends on:** Plan A merged (done, `a3b5a24`). **Priority:** P2. Related:
**T-DR** overlaps K1's snapshot needs / O5's `snapshot_schedule`; **T8**
(Tekton Chains) uses the `policies` seam O4 must preserve.

### zot registry auth — planning session — P2

**What:** design real auth for the local (and eventual production) zot. T7b0
ships it **credential-free** on the single-user OrbStack VM (stated threat model:
all cluster writers are the operator's). **Why:** a credential-free registry lets
any cluster workload push an image or attach a referrer; `attestation-sign.sh`
selects evidence by `last`-of-artifactType. Fine solo, not fine with a second
operator or a shared cluster. **Options to weigh:** static htpasswd Secret,
zot's OIDC/LDAP, an OpenBao-issued short-lived credential. **First step:** decide
whether this folds into the deferred "Auth + multi-member DX" session (likely) or
stays separate. **Depends on:** T7b0 (zot exists). **Triggers with:** a 2nd
operator, a shared cluster, or `environments/production/`.

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
- **Interim (pre-Cilium) is handled in T7b1-followup** (this file, DONE): Z2
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

**Depends on:** T7c (local Flux — Cilium installs through it). **Priority:** P2
· runs after the T7 arc, likely alongside the Kyverno module design.

### T8 — Tekton Chains provenance — P2, planning session

**What:** Install Tekton Chains on the Phase-2 cluster; add a second OpenBao
Transit key (`chains-provenance-key`) with an access policy that denies it
`transit/sign` on `approval-key`; verify automatic signed SLSA provenance
per build (`cosign verify-attestation --key <chains-pubkey>`).

**Why:** the third supply-chain leg (how the build happened), signed
mechanically. `environments/local/openbao` already has an empty `policies`
input for the scoped policy.

**First task — RESOLVED:** the loopback blocker is gone. The in-cluster
OpenBao (ADR 0016) serves pods over TLS at
`https://openbao.openbao.svc.cluster.local:8200` with k8s-ServiceAccount
auth. Chains adds a `chains-provenance-key` Transit key + a scoped policy
(deny `transit/sign` on `approval-key`) + a `chains` k8s-auth role — the
`transit_keys` / `policies` extension points on `environments/local/openbao`
are the seam.

**Also in T8:** sign the `ci/` OCI bundles with a dedicated key
([ADR 0014](docs/adr/0014-tekton-defs-are-oci-bundles-in-ci.md)); land
byte-level build reproducibility (`SOURCE_DATE_EPOCH`,
`--output rewrite-timestamp=true`) alongside provenance + independent
rebuild verification.

**Priority:** P2 · **Depends on:** T7 (all of T7a–T7d) shipped.

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

### T9a — `mise run check` in CI — ✅ DONE (merged, PR #7, `7ae5ad0`)

**What:** `.github/workflows/check.yml` — every push and every PR to main
runs `mise run check` (the hk `check` hook: shellcheck, pkl, tofu
fmt/validate/test, cue fmt, ls-lint, ast-grep, bats, check-coverage). One
definition (`hk.pkl`), two entry points. Report-only (no branch
protection). Also fixed the one Linux portability break (`stat -f '%A'` →
`tests/lib/assert.bash` `file_mode()`), made the `[docker]` bats cases
CI-fatal instead of skip-on-no-docker, added failure diagnostics
(`bats --print-output-on-failure`, un-silenced docker fixtures), and a
pitchfork-supervisor pre-start step (the lazily-spawned supervisor
inherited `hk`'s output pipe and hung it for 25 min — run 34142628643).

**Verified:** warm run 34144986089 green (4m); negative test 34145802826
red naming the suite; `[docker]` cases execute (no silent skip).

**Branch protection — deliberately NOT added.** Solo repo: the only admin
is the maintainer, so `enforce_admins=false` exempts every ordinary push
(not just emergencies) and `enforce_admins=true` adds a recurring
break-glass ritual the Operational Lifecycle Trace flags as a flaw. CI
`check` stays advisory. **Revisit trigger:** a second committer joins the
repo — then a PR-gated `required_status_checks` flow earns its keep.

### T9b — per-commit bisect-safety history gate — ✅ RESOLVED BY POLICY (no code)

**Outcome:** dropped. The bisect-safety goal is met by a **squash-merge
policy** instead of a per-commit replay workflow. The repo now allows
squash merges only (merge-commit + rebase disabled, head branch
auto-deleted, `gh api` repo settings), so every push to `main` is one
commit and `check.yml` (T9a) verifying that commit == full per-commit
`git bisect` safety, for free.

**Why not build the standing matrix:** ~7 min runner time per intermediate
commit on every push, redundant with `check.yml` on the tip/merge, low hit
rate for a solo dev who commits carefully and runs `mise run check` per
phase by hand, and a 3rd workflow + dynamic matrix + enumerate script +
aggregate job to keep green. Negative space beats it.

**If bisect through pre-policy merge commits is ever needed** (`4510b1a`
etc. never ran `mise run check` in isolation): `git bisect run` with a
predicate that does `mise install && mise run check`, exit 125 to
`git bisect skip` on an infra/install failure. Pay the cost only when
actually bisecting; no standing CI. Not built — write it if the need
appears.

**Recorded in:** `CLAUDE.md` § CI check gate & merge policy;
`docs/designs/digest-as-source-of-truth.md` § Phasing.

### T10 — VEX hardening — P3, post-T8

**What:** Promote the scan-clean-first posture to an enforced mechanism:
`.openvex.json` statement(s) → `vexctl attest` (signed via an OpenBao
Transit key, same custody as approval/provenance) → attached as an OCI
referrer → `mise run frontend:deploy` re-runs `trivy image --vex <referrer>
--severity CRITICAL --exit-code 1` against the SBOM referrer before
accepting a digest.

**Why:** an unsigned, consume-unenforced VEX statement buys no present
enforcement benefit; this is where the benefit lands. `vexctl`
(`aqua:openvex/vexctl`) is already pinned.

**Priority:** P3 · **Depends on:** T8 (Chains signing infra).

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

### Decide public hosting for cv_frontend

**What:** Choose where the actual public `cv_frontend` site lives for a
hiring manager to visit — separate from the demo/proof deploy T5b adds (a
standalone `pitchfork`-supervised Docker container on this dev Mac —
`docs/adr/0009-demo-consumer-is-local-container-not-k8s.md`).

**Why:** Anything running on this dev Mac — whether the earlier
k8s-namespace plan or T5b's pitchfork container — is tied to a single
machine staying on, not a reasonable uptime story for a public site.
Candidates worth evaluating: Vercel/Netlify (Remix has first-class
adapters for both), or the eventual `cluster-k0sctl` production cluster
once it exists.

**Context:** T5b deploys/runs `cv_frontend` from a verified image for proof
purposes only, deliberately not for real public hosting. See
`docs/adr/0009-demo-consumer-is-local-container-not-k8s.md` for the
demo-vs-real-hosting distinction.

**Effort:** S (research + decision) / M (actual setup)
**Priority:** P2
**Depends on:** digest-as-source-of-truth T5b (demo/proof deploy) proven


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

### Kyverno module — accumulating design inputs — P2/P3, planning session

Collects what the Kyverno module must cover before it is built (CLAUDE.md
§ Tool Boundaries pins Kyverno for admission policy; mechanics are deferred —
§ Deferred). Runs after `cluster-k0sctl` exists (the production cluster —
enforcing policy on the throwaway OrbStack dev cluster is not the point), and
likely alongside the Cilium planning session (this file — the two policy
engines' overlap is an open question there).

Known inputs so far:

- **Scope the `ci` namespace privileged allowance** (from `/investigate`
  2026-09-08). T7b1-followup adds one privileged step (`disable-ipv6`, step 0,
  runs `sysctl -w net.ipv6.conf.{all,default,lo}.disable_ipv6=1`, then exits)
  to the `git-clone` + `buildkit-build` pods — the interim IPv6 workaround.
  Today the `ci` ns is blanket PSA `privileged`. A Kyverno `validate` policy
  should turn that into a scalpel: permit `privileged: true` **only** on a
  container named `disable-ipv6` whose command is `sysctl`, and deny every
  other privileged container in `ns=ci`. This hardens N1 and is the right
  long-term home for it. (Note: if the Cilium planning session settles on a
  v4-only datapath, the `disable-ipv6` step goes away and this input is moot —
  sequence Kyverno after Cilium.)
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

### Kyverno ImageValidatingPolicy for real admission-time enforcement

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

### Upgrade cosign signing to public trust (Fulcio/keyless or published key)

**What:** Move both cosign keys (approval, Chains provenance) from
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
