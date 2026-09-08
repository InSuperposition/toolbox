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

### Auth + multi-member DX — planning session before T5 hardens

**What:** Run `/office-hours` then `/plan-eng-review` on the auth story for
the approval pipeline. T5 ships an *interim* auth (OpenBao root token for
signing, `gh auth token` for GHCR push) that works for a solo operator.
The full design covers: per-member OpenBao identity (an auth method +
per-member scoped policies so `transit/sign` on `approval-key` isn't the
root token), per-member registry auth (GHCR now, `zot` after T7c), the
`approval` Transit policy (which T8/Chains also needs), and a clean
`git clone → mise run attestation:sign` bootstrap for a new team member.

**Why:** The design's zero-trust claim is "possession of the private key is
the access control." In T5's interim form that collapses to "possession of
the OpenBao root token as a `0600` file on one person's machine." Anyone with it can
sign any `approvedBy` — there is no cryptographic per-approver identity.
That's acceptable for a solo proof; it is not acceptable once a second
person needs to approve, and building `attestation-sign.sh`'s auth twice is waste,
so the shape should be designed before hardening.

**Design lenses:** security (per-identity least privilege, no shared
long-lived secret), DX (a new member from clone to first approval in
minutes, not a runbook), bootstrap (idempotent, works on a fresh machine),
simplicity (an auth method, not a PKI), existing-stack fit (OpenBao auth
backends, `gh`; check whether Cilium/Kyverno play a role at the
cluster edge later).

**Context:** Surfaced by the 2026-09-06 T5 eng review.
`environments/local/openbao` already has an empty `policies` input ready
for the scoped policy. See `docs/designs/digest-as-source-of-truth.md`
§ Trust boundary and `docs/adr/0004-approval-key-openbao-transit-not-acl.md`.

**Effort:** planning ~1 session; implementation ~1-2d human
**Priority:** P2
**Depends on:** ~~T5 shipped~~ — **UNBLOCKED 2026-09-06.** T5 shipped its
interim auth: `attestation-sign.sh` signs with the root `VAULT_TOKEN` (the `0600`
`root.token` file, ADR 0011) and, for a
non-local registry, `gh auth token | cosign login` into an isolated
`DOCKER_CONFIG`; `approvedBy` is self-asserted. The `write:packages` scope
on the `gh` token is currently the operator's to arrange — this session
designs the real per-member story.

### T7 Phase-2 (Tekton) — re-cut, planned 2026-09-08

**Planning done.** `/plan-eng-review` (2026-09-08) + Codex outside voice
re-cut the whole arc around a **composable `ci/` concern** and
**digest-pinned OCI bundles**. Plan file:
`~/.claude/plans/t7a-buildkit-in-cluster-proof.md`. Key decisions
([ADR 0014](docs/adr/0014-tekton-defs-are-oci-bundles-in-ci.md)):

- Builder = **BuildKit, daemonless, rootless** (`buildctl-daemonless.sh` in
  the TaskRun pod — no buildkitd Deployment/Service). Chosen over
  `docker buildx --driver=kubernetes` (heavier — manages a pod) and
  kaniko/buildah. Registry cache, not a PVC. **KEDA scale-to-zero dropped** —
  no standing builder to scale.
- Reusable Tekton defs live in a new top-level **`ci/`** concern, **not
  `modules/`**. Distributed as OCI bundles (`tkn bundle push` → digest,
  bundles resolver, cosign-signable). Version = digest, no version-in-path.
  Per-consumer `PipelineRun` stays in `deploy/<consumer>/`.
- Tekton controller + `zot` installs are `environments/local/` concerns
  (Flux `OCIRepository`/`Kustomization`), not `ci/`.
- byte-level build reproducibility → **T8** (with Chains provenance).
- `deploy/frontend/Dockerfile` line 1 `# syntax=` gets **pinned by digest**
  in T7a (Codex: unpinned frontend = input-trust hole, distinct from
  timestamp reproducibility).

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

**T7b — the full pipeline as OCI bundles + GHA retirement.**
`ci/tasks/{trivy-scan,oras-attach}.yaml` (wrap the proven Phase-1 shell) +
`ci/pipelines/build-scan-approve.yaml` + `ci/scripts/pipeline-bundle-push.sh`
(`tkn bundle push` → digest) + `deploy/frontend/` `PipelineRun` (bundles
resolver `@sha256:` pins) + a digest-pinned `git-clone` step (two repos:
cv_frontend context, toolbox Dockerfile) + the registry cache + full
kubeconform/chainsaw harness. **Deletes
`.github/workflows/build-cv-frontend.yml`** only once build + evidence +
approval + consumption are demonstrated in-cluster end to end.
_T7b gaps to resolve in that session:_ in-cluster trivy DB strategy (PVC /
`--db-repository` OCI mirror / `--download-db-only` init); Task-step image
pins vs `mise.toml` host pins (drift); the two-repo `git-clone`; **the
staging becomes committed Tekton YAML, not shell** — `tekton-taskrun.sh`'s
two `<<-YAML` heredocs (per-run PV/PVC + TaskRun) go away entirely (the
`git-clone` Task + a `PipelineRun` replace the hostPath dance); shell never
authors YAML (from the T7a-follow-up review); **re-add a proper Tekton
`IMAGE_DIGEST` result** (T7a's Task pushes under a throwaway
tag and `tekton-taskrun.sh` resolves it — a Pipeline needs the result to pin
the next task; a committed `buildkit-extract-digest.sh` is a legal new file
here); **do not carry `.github/workflows/build-cv-frontend.yml`'s embedded
`run:` shell** (`:48` `tr` lowercase, `:98` digest-extract + `case` guard —
same logic the T7a Task refactor removed) into the Tekton pipeline —
extract to a tested script or delete with the workflow.
Effort: ~2-3d.

**T7c — local Flux.** flux2 + flux-operator (already pinned) reconciles
`ci/**` + `environments/local/` Kustomizations. Retires the interim
`local:tekton:install`. This lands **before** T7d so the zot install has a
reconciler. Effort: ~1-2d (includes the one-time Flux bootstrap:
operator install + first `FluxInstance` + deploy-key).
_Observability (from the CI-log-visibility review):_ once Flux reconciles
`ci/**` TaskRuns, persist **failed-step logs beyond `tkn taskrun logs`** —
via **Tekton Results** (needs its log-collection + a durable-storage
backend configured, not just the API installed). **Not** Tekton Chains —
Chains stores signed provenance/attestations, not stdout/stderr.
Acceptance test: a failed step's logs are retrievable *after* the TaskRun +
Pod are deleted. `tekton-taskrun.sh`'s failed-run object retention (the
`cleanup()` keep-on-failure path) is interim inspection, not durable
storage. Mirrors the GHA-side fix (`check.yml` uploads
`$HK_STATE_DIR/{output.log,hk.log}` as an artifact).

**T7d — GHCR → zot.** zot on orb via the now-present Flux (vendored upstream
in `environments/local/tekton/`… `environments/local/zot/`). Repoint the
pipeline + `deploy/frontend/` consumer + the bundle registry at zot.
Effort: ~1d.

**Priority:** P2 · **Depends on:** ~~T5 + T5b~~ done. T7a→T7b→T7c→T7d in
order (T7c's Flux precedes T7d's zot install).

### T8 — Tekton Chains provenance — P2, planning session

**What:** Install Tekton Chains on the Phase-2 cluster; add a second OpenBao
Transit key (`chains-provenance-key`) with an access policy that denies it
`transit/sign` on `approval-key`; verify automatic signed SLSA provenance
per build (`cosign verify-attestation --key <chains-pubkey>`).

**Why:** the third supply-chain leg (how the build happened), signed
mechanically. `environments/local/openbao` already has an empty `policies`
input for the scoped policy.

**First task, real blocker:** Chains runs in a pod on OrbStack's k8s;
OpenBao listens on `127.0.0.1:8200`. Pods reach the host at
`host.orb.internal`, but only once OpenBao's listener is widened past
loopback — which means `tls_disable = true` has to become real TLS at the
same time.

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
