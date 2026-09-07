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

### Scripts-policy audit of the T5 / T5b shell — mostly ✅ DONE

Landed on `feat/openbao-machine-global-and-gate`: `hk.pkl` + `mise run
check` gate (was missing entirely); `export-approval-pubkey.sh` deleted →
one-line mise task; `openbao-preflight.sh` advice trimmed; `bootstrap` /
`reset` simplified (no `fnox`, no `security`, atomic file writes). Remaining
(P2, own pass): `consume.sh` readiness poll, `verify-approval.sh` cosign-
stderr `case`, `run.sh` trap dance, `helper.bash` split. Original scope
kept below for that pass.

### Scripts-policy audit of the T5 / T5b shell — P2, remaining reduction pass

**What:** Run `/plan-eng-review` (and `/office-hours` if it grows) on every
shell file added for T5 / T5b, against CLAUDE.md's Scripts Policy ("Scripts
are minimal, tested, and the last resort — never the first"; "Declarative
first: check for an existing tool, then a `mise.toml` task, only then write
a script").

**Why:** T5 / T5b landed leaning on scripts as the *first* tool, not the
last. Some were pre-sanctioned by the design doc; several were not, and a
few are heavier than "minimal". The build is working and tested, but the
shell surface conflicts with this repo's stated goals and should be pared
back deliberately, not left to accrete.

**In scope, per file:**
- `scripts/export-approval-pubkey.sh` (now `mise run export-approval-pubkey`,
  a one-line task) — **was not in the design**, invented
  during implementation. Its core job is one command (`cosign public-key
  --key openbao://approval-key --outfile ...`). The `openbao://` →
  `hashivault://` → `bao read | jq` fallback chain is unrequested
  complexity. Candidate: a `mise` task one-liner; decide whether any
  fallback is actually warranted (it is a design question, not an
  implementation detail).
- `attestation/scripts/openbao-preflight.sh` — moved out of `deploy/frontend/`
  in Phase 4a; Phase 4c corrected the stale sealed-state advice, reordered
  the init check before the seal check, and added `openbao-preflight.bats`
  (5 states + healthy). The thin-as-possible reduction review still applies:
  is `bao status -format=json` + one authed read the minimum?
- `deploy/frontend/scripts/frontend-deploy.sh` — the design said "`mise run consume`
  writes the new reference, then `pitchfork restart frontend`" (implying a
  task). It became a 69-line script. The atomic write + real readiness poll
  justify *some* script; check whether pitchfork's own `ready_port` +
  `ready_delay` + a thin task covers it, and whether the readiness reporting
  belongs in the script at all.
- `attestation/scripts/attestation-verify.sh` — error classification is
  done by **string-matching `cosign` stderr** (`*"invalid predicate
  type"*`, `*"accepted signatures do not match threshold"*`, …). Fragile —
  it depends on cosign's unversioned error text (Map-is-not-Territory).
  Check whether `cosign` / `cue` expose distinguishable exit codes, or
  `--output json`, that replace the grep.
- `deploy/frontend/scripts/frontend-serve.sh` — design-named; retry/backoff/signal-traps are
  genuine logic. Lightest-touch review: is the trap/child-process dance the
  simplest correct shape, or does pitchfork have a supervised-`docker`
  primitive?
- the per-concern `scripts/tests/helper.bash` fixtures — check for
  duplication across `attestation/` and `deploy/frontend/` (both now spin a
  zot registry + cosign key via `tests/lib/registry.bash`). The
  `deploy.bats` docker-path split is **done** (Phase 4b: `frontend-serve.bats`
  / `frontend-deploy.bats`).
- `attestation/scripts/attestation-sign.sh` — design's one sanctioned
  "real-logic" script. Lightest review: only that it has not absorbed
  responsibilities that belong elsewhere.

**Also decide:** whether the `TOOLBOX_*` env test-seams
(`TOOLBOX_APPROVE_KEY`, `TOOLBOX_APPROVAL_PUBKEY`, `TOOLBOX_APPROVED_BY`,
`TOOLBOX_FRONTEND_VERIFY_ATTEMPTS`, `TOOLBOX_CONSUME_READY_TIMEOUT`) are the
right seam or a smell.

**Constraint:** T5 / T5b are merged and tested — this is a *reduction*
pass, behavior-preserving, with the bats matrix as the regression net. Not
a rewrite.

**Effort:** planning ~1 session; implementation ~0.5–1d
**Priority:** P1 (do before T7, which adds a lot more YAML/shell)
**Depends on:** nothing — the merged state is the input.

## Infrastructure

### Repo restructure — strict ownership boundaries — P0–P4 DONE, P5 (docs sweep) LEFT

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
| T6 | 5 | docs-accuracy sweep — every `.md` re-verified against the moved code (`digest-as-source-of-truth.md` still shows pre-restructure `approve.sh`/`verify-approval.sh`/`consume.sh` paths + a "4-way" preflight) | pending |

**Phase 1b–1d carry-overs** (not blockers):

- ~~`environments/local/tests/*.bats` adopt `scratch_copy` in Phase 2~~ —
  done (Phase 2 moved the dir to `environments/local/scripts/tests/` and
  they now use `scratch_copy`).
- `tests/lib/assert.bash` not created yet — added when a suite first needs
  a structured assertion. Existing `[ "$status" -eq N ]` checks stay.
- ~~**C4** (`attestation/` scratch + a default-`TOOLBOX_ATTESTATION_VERIFY`
  case)~~ — done in Phase 4b: `scratch_frontend` copies both `attestation/`
  + `deploy/frontend/` + a `mise.toml` marker, every scratch test runs on
  the un-overridden seam, and `frontend-serve.bats` has an explicit
  positive default-seam case.
- `frontend_isolation` names the container `toolbox-frontend-test-$$-<n>`;
  the real deploy still defaults to `toolbox-frontend` / host port 44100.
- **Re-run the clean-checkout check after Phase 2** (C5): `git clone . <tmp>
  && cd <tmp> && mise install && mise run check` — the OpenBao `git mv`
  changes tofu module paths and the `hk` tofu globs.
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

**Merge order:** all phases landed as commits on `main` (solo repo). P5
(docs sweep) remains.

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
git add deploy/frontend/cosign-approval.pub && git commit
```
No `fnox.toml` / keychain step — the secrets are `0600` files (ADR 0011).
Every attestation signed with the old key stops verifying against the new
`cosign-approval.pub` — re-run `mise run approve` for any image whose
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
`git clone → mise run approve` bootstrap for a new team member.

**Why:** The design's zero-trust claim is "possession of the private key is
the access control." In T5's interim form that collapses to "possession of
the OpenBao root token as a `0600` file on one person's machine." Anyone with it can
sign any `approvedBy` — there is no cryptographic per-approver identity.
That's acceptable for a solo proof; it is not acceptable once a second
person needs to approve, and building `approve.sh`'s auth twice is waste,
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
interim auth: `approve.sh` signs with the root `VAULT_TOKEN` (the `0600`
`root.token` file, ADR 0011) and, for a
non-local registry, `gh auth token | cosign login` into an isolated
`DOCKER_CONFIG`; `approvedBy` is self-asserted. The `write:packages` scope
on the `gh` token is currently the operator's to arrange — this session
designs the real per-member story.

### T7 Phase-2 (Tekton) — full planning session before any code

**What:** Run `/office-hours` then `/plan-eng-review` on Phase 2 of
`docs/designs/digest-as-source-of-truth.md` (§ Phasing) and
`docs/adr/0003-tekton-pipelines-on-orbstack-k8s.md` before implementing
T7a/T7b/T7c. Phase 2 is deferred after T5/T5b; it is NOT
implementation-ready.

**Why:** The 2026-09-06 `/plan-eng-review` scope-reduction pass found T7 as
written bundled the cluster, Tekton install, the builder-choice spike, the
full pipeline, the test harness, and the GHCR→zot migration into one task
(8+ files, 3+ new services) — too much for one design pass. `kaniko` was
carried in as an unvetted candidate (it was never in the original design);
the builder is genuinely undecided.

**Design lenses to apply in that session (owner-specified):**
- **Security** — rootless build, pod privilege model, supply-chain posture.
- **BuildKit-remote** — leading builder candidate; one engine across Phase 1
  (`docker buildx`) and Phase 2 (`docker buildx create --driver=kubernetes
  --driver-opt=rootless=true`). Alternatives: `chainguard-forks/kaniko` /
  `osscontainertools/kaniko`, `buildah`.
- **Scaling** — evaluate **KEDA** for scale-to-zero on the BuildKit builder,
  and on Tekton controllers, `zot`, and any other idle-most-of-the-time
  service.
- **Simplicity + negative space** — keep the stack as small as possible;
  every added component must justify itself against what's NOT added.
- **Innovation** — combine proven pieces in a simpler way where possible.
- **Existing-stack fit** — check Kyverno, Cilium, Flux, OpenBao first before
  adding anything new. Cross-ref the "Kyverno ImageValidatingPolicy" TODO
  below — admission-time enforcement may belong in this same design.

**Context:** T7a = builder spike (live probe on `orb start k8s`, push to
GHCR). T7b = wrap `build→scan→oras-attach` as Tekton Tasks + Pipeline +
kubeconform/chainsaw harness. T7c = GHCR→zot migration. See the
architecture doc § Phasing (Phase 2).

**Effort:** planning ~1-2 sessions; build T7a/T7b/T7c ~3-5d human total
**Priority:** P2
**Depends on:** T5 + T5b shipped and proven

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

**Priority:** P2 · **Depends on:** T7 (Phase 2) shipped.

### T9 — bisect-safety CI gate + `mise run check` — P1

**What:** Wire `hk.pkl` as the git-hook gate (shellcheck, bats,
lint/format per touched filetype) and expose the identical checks as
`mise run check` for manual/CI use — one definition, two entry points. Add
`scripts/check-history.sh` (rebuild-in-isolation per commit in a pushed
range), invoked CI-side via `mise run check` (async — a full isolated
rebuild per commit is too slow for a pre-push hook), wired as a required
GitHub status check.

**Why:** there is currently **no automated lint/test gate at all** — every
commit is `shellcheck` + `bats` + `tofu test` by hand. This is Phase 4 of
the design and independent of Phases 1–3.

**Scope note:** the history gate proves *historical buildability* only
("this commit's suite passed with the tool versions pinned at that
commit") — it does not re-check today's CVE policy against old commits.

**Priority:** P1 (do before T7 adds more shell/YAML) · **Depends on:**
nothing.

### T10 — VEX hardening — P3, post-T8

**What:** Promote the scan-clean-first posture to an enforced mechanism:
`.openvex.json` statement(s) → `vexctl attest` (signed via an OpenBao
Transit key, same custody as approval/provenance) → attached as an OCI
referrer → `mise run consume` re-runs `trivy image --vex <referrer>
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
