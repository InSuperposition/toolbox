# TODOS

Open work, phase sequencing, and planning-session triggers (CLAUDE.md §
Docs layout). Completed work lives in commit messages, PRs, and ADRs —
this file keeps only a git-log-density pointer to it, not a diary.

## Guiding principles for open work

Every item below is scoped and executed against the same bar, in order
when two of these trade off: **deterministic > declarative > correct >
simple.** Concretely — research an existing tool's own declarative
feature (a native CLI flag, a Tekton result, a schema) before adding a
hand-rolled script or template; prefer the option that produces the same
output every time over one that depends on call order or ambient state;
never trade correctness for either of the above; and once two options
are equally correct and declarative, the simpler one wins. The Kyverno
amd64-index admission fix (PR #55, below) is the concrete precedent: the
first draft proposed propagating a new value through three Tekton
YAML files; researching `oras`'s own `--platform` flag replaced that
with a single-script, single-flag fix — fewer files, less hand-rolled
logic, not more. New items written from here forward get plain
descriptive titles, not a new `T<n>` number — the existing `T7`/`T8`/
`R1b-ii-c`-style references stay as-is (renaming them is its own tracked
task, below: "Documentation extraction").

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
  - `zot registry auth` — CLOSED (2026-09-15, SPIRE Phase 1 PR 3 +
    buildkit-build wiring) — mTLS enforced, real Task presents a live SVID
    on every push; both proven live end-to-end
  - `Flux / registry CA trust` — open again, undecided; its only
    candidate mechanism (host-side SPIRE Agent) is not viable, see
    `SPIRE — phased workload-identity rollout` below
  - `SPIRE — phased workload-identity rollout` — CLOSED, Phases 0-1
    shipped; Phases 2-3 dropped (not viable / depended on Phase 2)
- *tofu modules*
  - `Retrofit vm-orbstack, cluster-k0sctl, secret-openbao to digest-pinning`
- *Kyverno/Cilium*
  - `Cilium — planning session needed`
  - `Plan B — deferred follow-ups` — the ship arc (M1→X1→K1→M3) is done,
    see Recently Closed; this is the deferred-items table
  - `Kyverno module — accumulating design inputs`
- *cv_frontend hosting*
  - `Decide public hosting for cv_frontend`
- *documentation*
  - `Documentation extraction — code comments + TODOS.md's own T-number/
    date litter`

**P3**

- *Tekton/CI*
  - `R5 — OCI-bundle distribution of the ci/ defs` (now also owns signing
    the bundles, folded in from the old T8 scope)
  - `Build reproducibility (SOURCE_DATE_EPOCH, independent rebuild
    verification)` — split out from the old T8 scope
  - `T7d — production repoint`
  - `Pin-drift guard: host mise.toml vs ci/tasks/* step images`
  - `Run-scoped digest identity — race-simulating test` — empirical proof,
    deferred from the shipped fix (provable by construction today)
  - `Tekton Dashboard`
  - `T10 — VEX hardening` — mechanism shipped, signed authorship deferred
  - `Publish a multi-arch image once a real amd64 consumer exists`
- *Kyverno/Cilium*
  - `Kyverno ImageValidatingPolicy for real admission-time enforcement` —
    now specifically the production-cluster instantiation
- *tooling cleanup*
  - `OpenBao's own tooling surface — bao CLI vs. direct API calls`
  - `openbao-verify.bats — convert error-path tests from live network to stubbed unit tests`
  - `Upgrade cosign signing to public trust`

## Recently closed

Newest first. Git-log density — commit/PR references, not a transcript.
Full detail lives in the referenced PRs, ADRs, and commit messages.

- **T7a-follow-up — resolved, not renamed — DONE** (`/plan-eng-review`).
  `frontend-build.sh` / `frontend-publish.sh` / `attestation-sign.sh` /
  `attestation-verify.sh` each orchestrate multiple pinned tools with none
  dominant (Tekton+oras+CUE; Timoni+flux; cosign+OpenBao+CUE) — forcing a
  single tool into `<domain>-<verb>.sh` would misdescribe the script, not
  clarify it. Given the choice between three rename schemes (dominant-tool
  guess, verb-first `op-*.sh`, or a documented policy exception), picked
  the exception: CLAUDE.md's Scripts Policy now names these four as the
  only `<domain>-<verb>.sh` files where `<domain>` is a concern, not a
  tool. Zero file renames, zero churn to `mise.toml`/ADRs/bats.

- **T10 — VEX suppression mechanism — DONE** (`/plan-eng-review`, re-verified
  against the live pinned trivy 0.74.0 before landing, not the original
  task text). `ci/tasks/gate.yaml` gains an `IGNOREFILE` param (default
  `/dev/null` — always present, always empty, byte-identical behavior to
  before this param existed) applied via `trivy convert --ignorefile`;
  `ci/pipelines/build-scan-approve.yaml` threads it through;
  `deploy/frontend/pipelinerun.cue` points it at the new, committed-empty
  `deploy/frontend/vex/.trivyignore`. Live-verified before writing any
  YAML: `trivy convert` has no VEX-format support at all (only `trivy
  image`/`trivy sbom` read OpenVEX, and both need a live vulnerability-DB
  call); `--ignorefile` on a nonexistent path FATALs (exit 1), ruling out
  a "pass an optional empty string" design; `/dev/null` works as the
  always-valid empty default. Full `ci/tests/build-pipeline/chainsaw-test.yaml`
  suite (including the 3 existing standalone `gate` TaskRun fixtures) still
  passes unchanged against the real cluster — the default made this a
  zero-test-change addition. Signed OpenVEX authorship (`vexctl` +
  a new OpenBao Transit key) deliberately deferred — see the item's own
  entry above for why.

- **Resolved-dependency-graph boundary check — DONE** (`/plan-eng-review`).
  Evaluated the three named candidates (`conftest`/OPA, `tofu graph`,
  CUE/Timoni schemas) against ground truth first: a repo-wide check of
  every actual cross-concern reference found zero current violations in
  any of the three gap categories the design doc names, and `tofu graph`
  turned out not to address the real HCL risk at all — it shows
  intra-unit resource dependencies, not the `file()`/`templatefile()`
  path arguments that could actually climb a concern boundary. Closed the
  two gaps that needed zero new tooling, reusing patterns already proven
  in this repo: `tests/check-tf-path-boundary.sh` (new `git grep` sibling
  to `check-tf-boundary.sh`, wired as the `no-cross-concern-tf-paths` hk
  step) denies a `file()`/`templatefile()`/`filebase64()` call whose
  literal path climbs into a sibling concern; `rules/boundary-yaml-manifest-ref.yml`
  + `rules/boundary-yaml-ci-ref.yml` (new `ast-grep` YAML rules — it
  already parses YAML) deny a `kustomization.yaml`/Flux `Kustomization`
  manifest-ref crossing a concern boundary, correctly excluding the
  already-documented `configMapGenerator.files:` read of
  `attestation/cosign-approval.pub` (a data ingestion, not a manifest-ref).
  Found and fixed in passing: `docs/designs/repo-structure.md`'s
  allowed-edges diagram was missing a real, already-shipped edge
  (`environments/local/flux/frontend.yaml` → `deploy/frontend/k8s`) —
  caught by ground-truthing every `kustomization.yaml`/Flux CR `path:`
  before writing the rule, not by trusting the diagram. Also fixed 3 bare
  PR-number/session-tag citations living in `rules/*.yml` `message:`
  fields — missed by the earlier comment sweep because they're YAML
  prose, not `#`-comment lines. The third gap (a shell-variable-assembled
  path, or a cross-language TOML/Pkl task reference) stays explicit
  accepted risk — zero observed violations, and closing it soundly needs
  a new tool for a category with no live instance; reopen the next time a
  violation of this shape is actually caught in review.

- **Kyverno build-pod securityContext enforcement — DONE** (`/plan-eng-review`).
  New `buildkit-build-posture` `ValidatingPolicy` (`policies.kyverno.io/v1`,
  matching the existing `ImageValidatingPolicy`'s CRD family rather than
  the legacy `ClusterPolicy`) enforces the spike-proven rootless-BuildKit
  ceiling — exact `runAsUser`/`runAsGroup`/`runAsNonRoot`,
  `seccomp: Unconfined`, `allowPrivilegeEscalation`, capabilities exactly
  `drop:[ALL] add:[SETUID,SETGID]` — as an allow-list at admission, on any
  pod's container literally named `build` (verified unique across all 5
  `ci/tasks/*.yaml` Tasks, so no separate Tekton-label matcher is needed;
  vacuously true, and live-verified unaffected, on every other container).
  Scoped by a `toolbox.dev/build-posture: enforced` label on `ci` (not a
  literal namespace-name match — needed so chainsaw's ephemeral test
  namespace is also covered). Live-verified end to end on the real
  OrbStack cluster: CEL compiles and the policy goes Ready, an
  exact-ceiling pod is admitted, a `privileged: true` or extra-capability
  (`SYS_ADMIN`) `build` container is denied, a non-`build` container with
  a fully privileged securityContext is unaffected. This is deliberately
  the narrower half of "Kyverno `ci`-namespace privilege policies" (below)
  — the `disable-ipv6` PSA-scalpel half stays blocked on its own trigger,
  since a Cilium v4-only datapath may delete that step's target entirely.
  Complements, not replaces, `ci/tests/build-pipeline/chainsaw-test.yaml`'s
  static assert that the Task manifest itself is this shape.

- **OpenBao tooling surface + openbao-verify.bats fail-closed fix — DONE**
  (PR #59 doc plan, PR #60, PR #61; `/plan-eng-review` + Codex outside
  voice, 13 findings folded). PR A: `openbao-bootstrap.sh`'s 2 direct-API
  call sites (`pf_refresh()`, the Phase A endpoint check — the only 2 in
  the whole repo) swapped for a `bao_reachable()` helper using `bao
  status`'s own exit codes + `VAULT_CLIENT_TIMEOUT` (undocumented,
  live-verified) instead of a hand-rolled curl health-probe override;
  also fixed a pre-existing bug where `pf_refresh()` silently succeeded
  after exhausting all retries. PR B: `openbao-verify.sh` had two
  blanket `|| skip (offline)` branches that silently passed on a
  malformed ref or a real render error (not just a network blip) — new
  `classify_failure()` fails closed on auth/cert/malformed-ref while
  preserving the already-shipped not-found/DNS-down skip behavior; the
  anti-rotation guard moved to run before every other check in the
  script; `openbao-verify.bats`'s error-path cases converted off the old
  `online()` TOCTOU-prone live-network gate onto a new local TLS zot
  fixture (`tests/lib/registry.bash`'s `start_registry_tls()`, no auth
  support — bcrypt needs an undeclared `htpasswd` system dependency, so
  auth-failure is unit-tested against real, live-captured oras error
  text instead). Both PRs live-verified against the real OrbStack
  cluster / real ghcr.io+quay.io, not just bats.

- **Remove `crane` from the stack entirely — DONE** (`/plan-eng-review`,
  1 Codex outside-voice pass). `crane`'s only remaining use
  (`openbao-verify.sh`'s two digest-equality gates) swapped to `oras
  resolve` — byte-identical digest output live-verified across 2
  registries (ghcr.io, quay.io) and 3 failure classes (DNS-down,
  malformed ref, not-found), plus the same bare-ref (no `oci://`
  scheme) requirement. `google/go-containerregistry` dropped from
  `mise.toml`. Codex's outside-voice pass found the plan's own file
  inventory was incomplete (6 more files + a missed `command -v crane`
  preflight line inside the script itself) — folded in before shipping,
  13 files total: the script (2 calls + the preflight), the bootstrap
  bridge's own preflight, `openbao-verify.bats`'s `online()` helper
  (fixed to check both registries, closing the separate pre-existing
  "online() checks only one of two registries" gap as a side effect),
  a `zot-trust.sh` comment, 5 lock-file manual-regen runbook comments,
  `variables.tf`/`main.tf`/`hk.pkl`/`repo-structure.md`/
  `environments/local/README.md`'s own current-behavior descriptions,
  and one unrelated pre-existing stale message in `frontend-build.sh`
  (still said "crane output" though `registry-seed.sh` moved to `oras`
  back in R1b-ii-c). Two follow-ups split out rather than folded in:
  "OpenBao's own tooling surface — `bao` CLI vs. direct API calls" (the
  item's own second half, genuinely separate scope) and
  "openbao-verify.bats — convert error-path tests from live network to
  stubbed unit tests" (a Codex finding on the bats suite's TOCTOU gap
  and thin error-path coverage — real, but a test-architecture change
  bigger than a tool swap).

- **Kyverno amd64-index admission fix — DONE** (PR #55, `/investigate` +
  `/plan-eng-review`, 2 Codex outside-voice passes). Kyverno's
  `ImageValidatingPolicy` denied every real `cv-frontend` image since T8
  started pushing `attest:provenance` multi-manifest indices —
  `verifyAttestationSignatures`/`extractPayload` default to `linux/amd64`
  resolving an index, no policy-level override exists. Two real
  redesigns: (1) user directive to research tools before more Tekton
  YAML — `oras resolve/attach/manifest fetch --platform` all exist and
  work exactly as documented (live-verified), replacing a go-template
  hack with one flag; BuildKit's `--metadata-file` does NOT expose a
  per-platform digest in any shipped release. (2) Codex found the
  resulting propagate-a-new-Task-result plan wouldn't even compile
  (Tekton has no value-templating for Task-level results, confirmed by a
  live spike) AND would reintroduce a cross-run evidence-collision
  ambiguity (the INDEX digest is always run-unique — it embeds a
  per-run provenance timestamp — the PLATFORM digest can collide across
  byte-identical rebuilds). Fixing #2 by keeping evidence on the index
  resolved #1 as a side effect: zero Tekton YAML touched in the end.
  Ships: `attestation-sign.sh` resolves the platform digest via
  `oras resolve --platform=linux/arm64` right after registry-transport
  setup; evidence discovery stays on the index ref; the predicate
  digest, signed subject, bundle referrer, and printed
  `frontend:publish` line all switch to the platform ref. Two chainsaw
  fixtures (`kyverno-reconcile`, `frontend-delivery`) re-pinned to the
  platform digest; `frontend-delivery`'s pod-selection assertions also
  gained a digest match — they previously selected any Pod by label
  alone, so a stale surviving Pod could satisfy both "container started"
  and "admitted by policy" regardless of whether a NEW admission attempt
  ever succeeded (confirmed: this test would have passed throughout the
  entire period the bug was live). New `tests/lib/registry.bash` helper
  (`make_multiplatform_image`) — a genuine OCI index fixture, not a
  stubbed `oras` binary. **Verified live end-to-end**: a real
  `mise run attestation:sign` + `mise run frontend:publish` + Flux
  reconcile produced a genuine NEW ReplicaSet whose pod reached `1/1
  Running` — real admission, not a stale survivor. `mise run check` went
  fully green, including `kyverno-reconcile` — broken since T8 shipped,
  the first fully clean run this session. Supersedes the open
  `kyverno-reconcile chainsaw fixture — stale hardcoded digest` item
  (removed, below — this entry's own fix is that item's resolution).

- **Run-scoped build digest identity — DONE** (`/plan-eng-review`
  2026-09-15, 1 Codex outside-voice pass, 5 findings folded). Reversed
  the original T7b OPEN-1 "no Tekton result" call
  (`~/.claude/plans/t7b-pipeline-recut.md:183`) — that call was right for
  its own scope (digest only ever needed post-hoc, `alpha` not worth
  spending for that alone); two things changed: `provenance-sign` (T8)
  now needs correct digest addressing INSIDE the pipeline, and
  `enable-api-fields: alpha` is already sunk for T8's `stdoutConfig`.
  Ships: `buildkit-build.yaml`'s `build` step gains
  `--metadata-file=/tekton/home/build-metadata.json`; a new
  `extract-digest` step (jq, `-e` + regex validation, `stdoutConfig`)
  produces a Task-level `IMAGE_DIGEST` result (the pushed INDEX digest,
  captured at push time — never a later `oras resolve` of the mutable
  tag); propagated as a Pipeline-level result and a `DIGEST` param to
  `scan-attach`/`provenance-sign`, which now address the image by
  `$(params.IMAGE)@$(params.DIGEST)`, never
  `$(params.IMAGE):$(params.APP_REVISION)`. `frontend-build.sh` reads the
  same Pipeline result instead of its own post-hoc `oras resolve` — one
  source of truth. **Codex outside-voice (5 findings, all folded):**
  (1) the original plan's `--metadata-file` path targeted a nonexistent
  `shared` workspace on `buildkit-build` — fixed to `/tekton/home`,
  Tekton's own pre-created per-pod directory, already proven shared
  across steps by the T8 hotfix; (2) `provenance-sign`'s old
  `discover-referrer` step picked `.referrers[0]` on the platform digest
  — a first-match pick, ambiguous if two runs ever produce a
  byte-identical platform manifest with different provenance (plausible:
  same source, same Dockerfile, unchanged deps) — replaced by
  `resolve-attestation-digest`, which derives the attestation manifest's
  digest from BuildKit's own OCI-native `vnd.docker.reference.type`/
  `vnd.docker.reference.digest` annotations on the SAME index (verified
  live against docs.docker.com's attestation-storage docs) — an exact
  match, not a guess; (3) the plan's own verification wording claimed
  scan-attach/provenance-sign land on "the SAME digest", which is false
  by design (index vs. platform digest are different values) — corrected;
  (4) `frontend-build.sh`'s `scan_refs` discovery stayed tag-addressed
  even after the digest fix landed elsewhere — reordered to read the
  digest first; (5) no test simulates the tag moving mid-pipeline —
  deferred to a new P3 item (below) with an explicit rationale (the fix
  is provable by construction — exact annotation match, not first-match
  — not empirically race-tested).

- **Promotion boundary for build-scan-approve — RESOLVED, documentation-only**
  (`/plan-eng-review`, Codex outside voice). Rejected a real registry-level
  promotion boundary (no zot-native feature; this repo's zero-trust model
  already enforces trust at consumption time — Kyverno admission +
  `frontend:publish`'s verify-first, never registry presence). Also
  rejected a narrower `-REJECTED` marker-tag `finally:` Task Codex found
  structurally unsound: no run-scoped digest identity means it can tag the
  wrong build on a rerun/concurrent-run collision, and even correct it
  doesn't address the stated risk (a `docker pull` shows nothing
  different). Shipped instead: `ci/README.md` § Trust boundary documents
  the direct-pull risk and corrects an overclaim (not "only a human"
  bypasses enforcement — automation outside the designated delivery path
  does too). No code, no new Task. Surfaced its own follow-up, tracked
  separately: `Run-scoped build digest identity` (above) — the same
  mutable-tag identity gap already affects `scan-attach`'s evidence today.

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
  **HOTFIX 2026-09-14 — six real bugs, none caught by the merge above,**
  all found live running the ACTUAL `build-scan-approve` Pipeline
  end-to-end (`mise run frontend:build`), not the isolated spikes PR #51
  verified with. Root cause of the miss: those spikes exercised BuildKit
  provenance and OpenBao auth as standalone Jobs, never the real merged
  Task/Pipeline wiring together — a `/plan-eng-review` of a *different*
  item ("Run-scoped build digest identity") surfaced the first bug via
  Codex outside-voice, which cascaded into finding the rest by testing
  for real. Fixed, in the order hit:
  1. `buildkit-build.yaml` never actually passed `--opt=attest:provenance=`
     — added, plus `vcs:source`/`vcs:revision` (needs the new
     `APP_REPO_URL` param, threaded through the Pipeline).
  2. `oras discover` against the tag/index found zero referrers —
     BuildKit's attestation manifest's OCI 1.1 `subject` points at the
     single-PLATFORM manifest (ADR 0008, arm64-only), never the index a
     tag resolves to once provenance makes the push multi-manifest.
     Fixed with a new first step, `resolve-platform-digest`, filtering
     the index for the entry whose `platform.architecture != "unknown"`
     (BuildKit's own sentinel for the non-runnable attestation entry).
  3. `oras manifest fetch --format go-template`'s output wraps every
     field under `.content` (`.content.manifests`, `.content.layers`) —
     unlike `oras discover`'s own output (`.referrers` at the top level).
     Both templates in `provenance-sign.yaml` fixed; caught only because
     this was the first time the real CLI path (not a `jq`-piped spike)
     ran.
  4. `scan-attach`'s trivy calls failed closed
     (`no child with platform linux/amd64 in index`) once `build`'s push
     became a multi-manifest index — trivy's platform auto-selection
     defaults to amd64. Fixed: new `PLATFORM` param (default
     `linux/arm64`, matching `buildkit-build`'s own), `--platform=` on
     both trivy calls.
  5. `openbao-login`/`cosign-attest` set
     `HOME=$(workspaces.shared.path)/openbao-home`, a PVC subdir nothing
     ever created — `bao login` authenticated fine but failed writing
     `.vault-token.tmp` (exit 2), so `cosign-attest` then skipped as a
     downstream failure. Fixed: `HOME=/tekton/home` — Tekton's own
     per-pod `emptyDir`, pre-created and already shared across every
     step's container (the convention `buildkit-build.yaml`'s `build`
     step already relies on) — no `mkdir` step needed.
  6. Even with the shared directory, cosign's read of the token still
     403'd `permission denied` — `bao login` writes `.vault-token` mode
     `0600`, owned by whichever UID the container ran as, and the two
     images default to DIFFERENT UIDs (`openbao`'s named `openbao` user
     vs. cosign's distroless `65532`). Fixed: both steps now pin the
     same explicit `runAsUser: 65532` (keeps the token owner-only, never
     loosened to world-readable).
  7. Sign itself then 403'd separately — the actual API call is
     `transit/sign/chains-provenance-key/sha2-256` (cosign's hashivault
     KMS client appends the hash algorithm), but the tofu policy
     (`environments/local/openbao/main.tf`) granted only the EXACT path
     with no suffix. Fixed: `transit/sign/chains-provenance-key*`, a
     Vault/OpenBao prefix match — covers the bare path and any suffixed
     variant. Locked in with a new `tofu test` assertion
     (`environments/local/openbao/tests/phase_c.tftest.hcl`), not just
     the fix.
  8. `cosign attest`'s registry PUSH to zot then failed TLS verification
     — `VAULT_CACERT` only configures the hashivault KMS client's Vault
     connection; the registry push is a separate Go `net/http` client
     (go-containerregistry) that doesn't read it. Fixed with
     `SSL_CERT_FILE` (Go's `crypto/x509` honors it on Linux — the pod's
     OS; the darwin exception that bites `crane`/`flux push` on the
     operator's Mac doesn't apply in-cluster).
  **Verified live end-to-end, not just chainsaw:** a full
  `mise run frontend:build` run against the real `cv_frontend` repo went
  green — `oras discover` against the resolved platform digest shows a
  real `application/vnd.dev.sigstore.bundle.v0.3+json` referrer, a
  genuinely cosign-signed SLSA v1 provenance statement, alongside
  BuildKit's own unsigned one. `ci/tests/build-pipeline/chainsaw-test.yaml`
  updated to match (`extract-predicate`/`cosign-attest` absolute-path
  `command:` values). **Not fixed, unrelated, flagged:** `mise run check`
  surfaced one pre-existing failure, `kyverno-reconcile`'s
  `an-approved-cv-frontend-pod-is-admitted` step — its fixture pins a
  hardcoded `cv-frontend@sha256:d0c92cb1...` digest that no longer
  exists in zot (confirmed 404). A different concern (the human-approval
  attestation fixture, not T8's provenance) — own P3 entry, below.

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

- **Plan B — Timoni + Kyverno + Crossplane boundary ship arc — DONE**
  (`M1 → X1 → K1 → M3`, each 1 PR = 1 squash commit) — **M1** #31
  (`b4c0b0c`, `deploy/frontend/timoni/` CUE module + `timoni mod vet`
  gate, ADR 0019); **X1** #32 (`d286867`, ADR 0018 —
  render→reconcile→enforce→provision pipeline staging, tofu
  `kubernetes_*` banned); **K1** #33 (`1dc6e91`, Kyverno v1.19.1 via Flux
  + one `ImageValidatingPolicy` gating `cv_frontend` at admission, ADR
  0020); **M3** #34 (`2c6a1e1`, `mise run frontend:publish` host step
  delivers via Flux OCIRepository/Kustomization into ns `frontend`, ADR
  0021). Live on `main`: `cv-frontend` runs 1/1 in ns `frontend`,
  admitted by the approval policy; `chainsaw-{kyverno,frontend}` pass
  post-merge. **Op note:** the interim zot is ephemeral + GC-off —
  recreate loses `D_man` → re-run `frontend:publish` + re-pin (like
  `frontend:seed`). Deferred tails — promoted to their own section,
  not lost: "Plan B — deferred follow-ups," below.

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
4. T8 (build provenance — DONE, see Recently Closed) — narrower and
   already shipped: a `chains-provenance-key` Transit policy
   (`chains_provenance_sign`) denying it `approval-key`, plus a
   dedicated `provenance-signer` ServiceAccount + `chains_provenance`
   k8s-auth role scoped to that key only, live in
   `environments/local/openbao/main.tf`. Confirms the trigger fired
   without reopening this whole session — T8's identity is scoped to
   PROVENANCE signing, not approval signing, so it did NOT close the
   human-approver gap this item is actually about. **Updated
   2026-09-15:** the SPIRE-backed idea for this gap (`SPIRE — phased
   workload-identity rollout`, below) was dropped — no viable host-side
   SPIRE Agent on the dev Mac (no darwin binaries). This gap stays open,
   unscoped by any current plan.

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

**Depends on:** nothing blocking — Plan A (T7c Increment 4, in-cluster
OpenBao) is done, see Recently Closed; this item is fully actionable
now, just not yet scheduled. **Overlaps:** Plan B O5 (`snapshot_schedule`).
**Priority:** P2. Surfaced by `/plan-eng-review` 2026-09-10 (+ Codex #6/#7).

### zot registry auth — CLOSED (2026-09-15, SPIRE Phase 1 PR 3)

**What it was:** T7b0 shipped zot **credential-free** on the single-user
OrbStack VM — any workload could push an image or attach a referrer.

**Closed by:** zot now requires a valid SPIFFE client cert (mTLS) to
push (`create`); anonymous read stays open (zot's `VerifyClientCertIfGiven`
listener mode, live-verified — a no-cert client is treated as anonymous,
not rejected). One real, already-existing identity — the `ci` namespace's
default ServiceAccount (what `buildkit-build`/`scan-attach` run as) — is
registered declaratively via `spire-server`'s own default `ClusterSPIFFEID`
(`controllerManager.enabled=true`, flipped back on from PR 2's negative-space
choice). Live-proven end-to-end: a real pod running as that ServiceAccount
fetched its SVID from the Workload API and pushed to zot via `oras`
(`--cert-file`/`--key-file`); an anonymous push to the same repo was denied
(`basic credential not found` / 401); anonymous read stayed unaffected (200).

**The buildkit-side wiring itself was a separate follow-up, now also
closed** (2026-09-15, see "Wire buildkit-build's real Task..." below) —
`buildkit-build`'s real Task now presents a live SVID on every push.

### Wire buildkit-build's real Task to present a rotating SVID — CLOSED (2026-09-15)

**What it was:** `ci/tasks/buildkit-build.yaml`'s `build` step (running as
the `ci` namespace's default ServiceAccount, a registered SPIFFE identity
per "zot registry auth" above) didn't present that identity to zot during
a real push.

**Closed by:** a new `fetch-svid` step (before `build`) runs the pinned
`spiffe-helper` binary directly — no embedded shell, no CSI driver needed.
`daemon_mode = false` (fetch once, exit) is correct for a Tekton step:
steps run sequentially in one pod lifetime, well under a fresh SVID's
~1h default TTL, so no rotation/reload machinery is needed — simpler
than the CSI-driver route originally assumed. The client keypair
(`[[registry."zot...".keypair]]`) is a **static** stanza baked directly
into the existing `ci/runtime/buildkitd-mirror.yaml` ConfigMap, same
footing as the file's existing `ca = [...]` entry it sits beside — the
file path is a build-time constant (this Task's own fixed emptyDir
mount), not something that rotates independently the way the CA
(deliberately kept out-of-band) does. No new script, no workspace
needed — the hostPath socket and the new ConfigMap are Task-owned infra
mounts (same class as `disable-ipv6`'s hardcoded sysctl values), not
consumer-parameterized data.

**Real bug caught by live verification:** `fetch-svid`'s `securityContext`
MUST match the `build` step's `runAsUser: 1000` — spiffe-helper's key
file is written `0600`; a UID mismatch between the two steps is a real
"permission denied" reading it at push time, not a hypothetical.

**Live-proven end-to-end, both directions:** a real `buildctl-daemonless.sh`
build+push to zot succeeded with the fetched SVID (`spiffe-helper`
correctly writes leaf+intermediate to `svid.pem` — verified live, unlike
an earlier session mistake with raw DER concatenation); the identical
push with no client cert failed `unauthorized: authentication required`.
`ci/tests/build-pipeline/chainsaw-test.yaml`'s step-count/posture
assertions updated and green live.

**Depends on:** "zot registry auth" (closed, above). **Priority:** was P2.

### Flux / registry CA trust — P2

**What:** R1b-ii-c hit a real wall: `flux push artifact` has no CA-file
override for a private registry CA, and the interim (`--insecure-registry`,
scoped to one call) is accepted only as time-boxed, not a destination. The
per-CLI-flag approach (that session's fix) treats each tool as its own trust
boundary, one at a time.

**Previously proposed mechanism, now dropped:** a host-side SPIRE Agent
(`join_token` node attestation on the dev Mac) was the picked direction.
Not viable — SPIRE ships no darwin release binaries at all (confirmed
via the GitHub releases API for spiffe/spire v1.11.0), only
`linux-{amd64,arm64}-musl` tarballs and a windows zip. Cilium's Mutual
Authentication was the other candidate and is also ruled out
(pod-to-pod only, confirmed Beta,
[docs.cilium.io](https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/)).
No live candidate mechanism remains.

**Open coordination question this item still owns:** whether this folds into
the deferred "Auth + multi-member DX" session, same as "zot registry auth"
above — decide both together, they're the same host-identity question from
two angles. **Depends on:** a new mechanism being found — none is currently
identified. **Triggers with:** a dedicated planning/research session, not
blocking R2–R4.

### SPIRE — phased workload-identity rollout — CLOSED (2026-09-15, Phases 0-1)

**What:** a corrected, cited map of every identity boundary in the repo
today, plus an ordered, small-transaction rollout of SPIFFE/SPIRE where it
closes an *already-open* gap — not a rewrite. Full plan: this entry
(inline, below) — the plan-file path previously cited here
(`~/.claude/plans/let-s-go-with-the-steady-treehouse.md`) was overwritten
by an unrelated, already-shipped "remove crane" plan and no longer holds
SPIRE content (found 2026-09-15); this section is the sole source of
record. Owns and is cross-referenced from: "zot registry auth", "Flux /
registry CA trust", "Auth + multi-member DX", T8, and the Cilium
planning-session entry (all this file).

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
  auth + X.509-SVID mTLS. **RESOLVED by Phase 0 (2026-09-15, ADR 0024):**
  `cert` auth rejected — OpenBao 2.6.2's `cert` backend unconditionally
  builds the identity alias from the client cert's Common Name, and
  SPIFFE X.509-SVIDs carry no CN by spec; login fails with `"missing name
  in alias"` even when `allowed_uri_sans` correctly matches (live-verified:
  a mismatched SVID is correctly rejected with a different error, `"no
  chain matching all constraints"`, proving the URI SAN gate itself works
  — it's alias creation afterward that hard-fails, with no config
  workaround). `jwt` auth + JWT-SVID remains the untried alternative if
  SPIRE-backed OpenBao auth is revisited; no phase currently plans to.
- **Registry-CA-trust "mesh" question** — Cilium's Mutual Authentication
  is confirmed pod-to-pod only, explicitly incompatible with external/host
  mTLS ([docs.cilium.io](https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/)) —
  does not answer the "Flux / registry CA trust" item's own question. A
  host-side SPIRE Agent (non-k8s node attestation via `join_token`) was
  the other candidate — also ruled out (2026-09-15, no darwin binaries);
  see that item's entry above. No mechanism currently answers this.
- **Tekton Chains** — not viable now, upstream alpha, "not yet functional"
  ([tekton.dev](https://tekton.dev/docs/pipelines/spire/)). T8 does not
  depend on this.

**Phases (each its own PR, gated on the previous phase's verification):**

0. **Spike — DONE (2026-09-15, ADR 0024).** Throwaway SPIRE Server +
   Agent + throwaway OpenBao container (all Docker, teardown after);
   confirmed OpenBao `cert` auth cannot authenticate a stock SPIFFE
   X.509-SVID (no CN → `"missing name in alias"`); `jwt` auth +
   JWT-SVID was the identified alternative, not pursued further. No
   production wiring landed; this was a finding, not code.
1. **SPIRE Server + Agent in-cluster; zot mTLS** — split into 3 PRs
   (Gall's Law / bisect-safety). **PR 1 — DONE (2026-09-15, #64):**
   OpenBao's `pki` mount as SPIRE's upstream authority (docs/adr/0025).
   **PR 2 — DONE (2026-09-15, docs/adr/0026):** the
   `environments/local/spire/` tofu unit (sibling to `openbao/`, same
   skeleton) — SPIRE Server + Agent via one `helm_release` of the
   upstream `spire` umbrella chart (`spire-crds` installs first, a
   genuinely separate release), `k8s_psat` node attestation
   (chart-default RBAC, no hand-authored roles), the intermediate cert
   signed by PR 1's OpenBao role at runtime, a dedicated `trust-manager`
   `Bundle` CR (`spire-vault-ca`) for OpenBao's own TLS trust, and an
   explicit `controllerManager.enabled = false` override (the umbrella
   chart's own default silently turns this on, which would have shipped
   a webhook + `ClusterSPIFFEID` CRs with no review). Live-apply against
   the real cluster caught 2 real config bugs neither the plan nor
   `tofu test` surfaced (both now fixed + regression-guarded in
   `spire.tftest.hcl`): (1) the vault plugin's `k8sAuth.token.audience`
   defaults to `"vault"`, not PR 1's OpenBao role audience
   (`var.openbao_endpoint`) — a live 403 "invalid audience" at
   spire-server startup; (2) `spire-agent.trustBundleFormat` (its own
   bootstrap-trust file format) is independent from
   `spire-server.bundlePublisher.k8sConfigMap.format` even though both
   read the same ConfigMap — a mismatch hangs the agent forever on
   "could not parse trust bundle". End-to-end proven live: node
   attestation succeeds, spire-server's active CA is upstream-signed
   (`self_signed=false`), both ConfigMaps populated, chainsaw green.
   **PR 3 — DONE (2026-09-15):** zot mTLS config (`http.auth.mtls` +
   `http.accessControl`, live-verified against the real project-zot
   v2.1.20 source — `identityAttributes` is a fallback chain,
   `anonymousPolicy` is a field DISTINCT from `defaultPolicy` that
   readiness probes actually need) + the cross-namespace bundle-ConfigMap
   repoint (`bundlePublisher.k8sConfigMap.namespace = "zot"`) +
   `controllerManager.enabled = true` (declarative registration via the
   chart's own default `ClusterSPIFFEID`, reversing PR 2's negative-space
   choice now that a real consumer exists). Live-proven end-to-end: a
   real pod running as the `ci` namespace's default ServiceAccount
   fetched its SVID and pushed to zot via `oras`; an anonymous push was
   denied; anonymous read stayed unaffected. Closed "zot registry auth"
   (above) for the mechanism; the follow-up (`buildkit-build`'s own Task
   presenting the SVID) is DONE too — see "Wire buildkit-build's real
   Task to present a rotating SVID," below.

**Not pursued — host-side SPIRE Agent (2026-09-15):** SPIRE ships no
darwin release binaries at all — only `linux-{amd64,arm64}-musl`
tarballs and a windows zip (confirmed via the GitHub releases API for
spiffe/spire v1.11.0). A host-native agent on the dev Mac cannot be
built as originally scoped (no alternate mechanism — a Linux container,
a VM — evaluated or picked). "Flux / registry CA trust" (above) and
the OpenBao-signing-identity idea (retiring `attestation-sign.sh`'s
root-token use) both depended on this and are dropped with it, not
carried forward as open items. Cilium Mutual Authentication remains not
scheduled, deferred to the Cilium planning-session entry (above),
reusing this Phase 1 SPIRE Server if/when it happens — never Cilium's
bundled one. Tekton Chains + SPIRE also stays not scheduled (upstream
not ready — see T8's entry).

**Operational Lifecycle Trace (SPIRE Server, shipped in Phase 1):**
bootstrap via a tofu unit + `spire-bootstrap.sh` (intermediate cert
from OpenBao PKI, registration entries declarative via the chart's own
`ClusterSPIFFEID` — never typed by hand); process restart — in-cluster
DB on a PVC survives; machine reboot — no manual step, cluster-native;
disaster — SPIRE's cert re-issues from OpenBao (already-recoverable
root), registration entries re-apply from the checked-in manifest. No
recurring manual step, no memorized secret — matches the standard
ADR 0011 already holds OpenBao to.

**Effort:** Phase 0 + Phase 1 shipped, ~2 sessions total.
**Priority:** P2 · **Status:** closed — Phase 0 and Phase 1 are the
full scope of this rollout now; nothing left pending under this entry.

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
**Depends on:** nothing blocking — Phase 1 (the mechanical build/scan/gate
pipeline) and Phase 2 (all of T7a-T7d's Tekton work) both shipped (Recently
Closed); fully actionable now, just not yet scheduled.

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

### Plan B — deferred follow-ups — P2

Plan B's ship arc (`M1 → X1 → K1 → M3`) is done — see Recently Closed.
What's left is this table of deliberately-deferred items, each with its
own trigger:

| Item | Trigger |
| --- | --- |
| **O4 / O5** — extract `modules/secret-openbao/` (`moved` blocks — `deletion_allowed=false` on `sops`/`extra` keys makes `tofu destroy` fail partway) + `ha` / `awskms`\|`transit` unseal / `snapshot_schedule` / `tls_issuer` presets. **ADR 0017**. | `environments/production/openbao/` becomes real planned work (the true 2nd consumer — one consumer is not a module, `modules/README.md`). ADR 0012 stands until then. O4 planning also picks up a dedicated OpenBao Transit `manifest-signing` key for the M3 artifact. Also: O4 should account for T8's shape (one named `vault_policy` resource per consumer — `chains_provenance_sign`, `main.tf` — not a generic `policies` variable, which doesn't exist) when it extracts this unit. |
| **Crossplane install** (core + `provider-*` + a Composition + its own ADR) | a consumer declares backing infra it does not own (bucket / DB / queue / DNS as a CR) — **not** a directory count. |
| **G1** — Flux SOPS (`--sops-vault-configmap` + ConfigMap + `spec.decryption`) | a named secret needs SOPS decryption. Plan A's Phase C left the OpenBao side (`sops` key, `flux_sops` role) ready. |
| **Manifest authorization** (Codex #7) — scoped RBAC for the `frontend` kustomize-controller SA + a defined rendered-manifest review path (image approval ≠ authz of the manifests around it) | own review/session. |
| **Kyverno `ci`-namespace PSA scalpel** (the `disable-ipv6` privileged allowance specifically) | `cluster-k0sctl` built + the Cilium planning session done — a v4-only datapath may delete the `disable-ipv6` step entirely, so scoping it now risks rework. (Also referenced from the "Kyverno module — accumulating design inputs" entry below — this table is the row's one home.) Build-pod securityContext enforcement shipped separately — see Recently Closed. |
| **`chainsaw-frontend` HTTP-200 assertion** | the cv_frontend Remix v3 boot crash is fixed (cv_frontend repo). |

**Depends on:** nothing blocking. **Priority:** P2. Related: **T-DR**
overlaps K1's snapshot needs / O5's `snapshot_schedule`.

### Kyverno module — accumulating design inputs — P2/P3, planning session

Collects what the Kyverno module must cover before it is built (CLAUDE.md
§ Tool Boundaries pins Kyverno for admission policy; mechanics are deferred —
§ Deferred). Runs after `cluster-k0sctl` exists (the production cluster —
enforcing policy on the throwaway OrbStack dev cluster is not the point), and
likely alongside the Cilium planning session (this file — the two policy
engines' overlap is an open question there).

Known inputs so far:

- **Scope the `ci` namespace privileged allowance** (the `disable-ipv6`
  PSA scalpel) — duplicates a row already in "Plan B — deferred
  follow-ups" (this file, above — "Kyverno `ci`-namespace PSA scalpel") —
  see there for the trigger, not restated here.
- **Build-pod posture enforcement — DONE**, see Recently closed. The
  `buildkit-build-posture` `ValidatingPolicy` now enforces this at
  admission, on the `build` container specifically.
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

### Documentation extraction — code comments + TODOS.md's own T-number/date litter — P2, planning session

**What:** two-part cleanup, same underlying problem. (1) CLAUDE.md §
Docstrings and Comments already states the rule for code: a comment
describes behavior-in-place, never planning narrative or a cross-file
reference. Audit where that's been violated — this session alone added
a lot of dense historical narrative ("HOTFIX 2026-09-14 — six real bugs,
none caught by the merge above...") directly into Tekton YAML and script
comments while debugging live — and extract the planning content into
`docs/designs/` or an ADR, leaving the comment itself behavior-only. (2)
This file's own `T7`/`T8`/`R1b-ii-c`-style numbering and dense inline
dates are the same failure mode in a different file: a newcomer can't
tell what `R1b-ii-c` means without archaeology, and a decorative
`2026-09-14` stamp on a sentence that isn't actually a trigger condition
is noise. Replace opaque references with plain descriptive titles
(already the convention this audit's own two new items use) and trim
dates down to only where one is load-bearing — an actual trigger
condition or a "why now" — not narrative color.

**Why:** both are the same root problem — planning/historical narrative
living somewhere it outlives its usefulness and actively confuses the
next reader, rather than in a doc whose whole job is holding history
(commit messages, PRs, ADRs, `docs/designs/`). Named explicitly by the
user during a TODOS.md audit pass (2026-09-15): "a messy situation, with
[not-]relevant dates and task ids that no one can understand."

**Not executed in this pass** — this audit only fixed staleness and
completion tracking; it deliberately doesn't rename anything (see this
file's own Guiding Principles note above on why new items get plain
titles going forward without touching the old ones yet).

**Depends on:** nothing blocking. **Priority:** P2.

### Resolved-dependency-graph boundary check — DONE, see Recently closed

Closed two of the three gap categories at zero new-tool cost
(`no-cross-concern-tf-paths` hk step + two new `ast-grep` YAML rules); the
third (a path assembled from a shell variable, or a cross-language TOML/Pkl
task reference) is explicit accepted risk, not silently missing — see
`docs/designs/repo-structure.md` § Enforcement / Honest scope for the
full breakdown and the reopen trigger.

### `spire-verify.bats` has no local-fixture rigor for chart-dependent cases — P3

**Found 2026-09-15** while writing SPIRE Phase 1 PR 2's test suite.
`environments/local/scripts/tests/openbao-verify.bats` stands up a
throwaway local TLS zot registry (`tests/lib/registry.bash`'s
`start_registry_tls`) for its digest-mismatch/malformed-ref cases —
no network, no flakiness. `spire-verify.bats` has no equivalent: the
`spiffe/helm-charts-hardened` repo is a CLASSIC (non-OCI, index.yaml +
bare `.tgz` over plain HTTP) Helm repo, and this repo's only existing
throwaway-registry fixture is OCI/zot-shaped. So `spire-verify.bats`'s
chart-dependent cases (the happy path, the mutated-digest fail-closed
case) run against the REAL live `spiffe.github.io` repo, self-skipping
offline — correct behavior, but flaky-by-network same as
`openbao-verify.bats`'s cases used to be before that suite got its
local fixture.

**Fix:** build a `tests/lib/helm_repo.bash` (or similar) — a throwaway
static HTTP server serving a hand-built `index.yaml` + a couple of
fixture `.tgz` charts, the classic-repo equivalent of
`registry.bash`'s `start_registry`/`start_registry_tls`. Convert
`spire-verify.bats`'s chart-dependent cases to use it.

**Priority:** P3 — not a real regression, a test-harness gap. Not fixed
here (out of scope for SPIRE Phase 1 PR 2; flagged per repo-ownership
discipline, same pattern as the `openbao-verify.bats` item above).

### Run-scoped digest identity — race-simulating test — P3

**What:** a chainsaw test that pushes a second image to the same tag
between `build`'s push and `scan-attach`'s run, and asserts
`scan-attach`/`provenance-sign` still process the FIRST run's captured
digest, not the tag's now-current one.

**Why:** empirical proof of run-isolation under the exact concurrency
scenario the "Run-scoped build digest identity" item itself was named
for, rather than resting on the structural argument alone. That fix
(`provenance-sign.yaml`'s `resolve-attestation-digest`, an exact
`vnd.docker.reference.digest` annotation match instead of a first-match
`oras discover` pick) makes the SPECIFIC ambiguity Codex found provable
by construction — reading the code proves it, the way a unique-key
lookup doesn't need a race test to prove it returns the right row — but
a genuinely different future bug in the propagation chain wouldn't be
caught without a live race test.

**Context:** surfaced by Codex's outside-voice review of "Run-scoped
build digest identity" itself (`/plan-eng-review`, 2026-09-15) — deferred
deliberately, not silently dropped, because designing a deterministic
mid-pipeline race injection in chainsaw isn't a solved pattern in this
suite yet, and the shipped fix's correctness didn't depend on it.

**Depends on:** the shipped fix (this item tests the mechanism it adds —
the `IMAGE_DIGEST` result, the `DIGEST` param threading, and
`resolve-attestation-digest`'s annotation-keyed lookup all need to exist
first). **Priority:** P3 — the current fix is provable by construction;
this closes the empirical gap, not a known-broken behavior.

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
**Depends on:** nothing blocking — T7b2 shipped (T7, Recently Closed);
fully actionable now, just not yet scheduled.

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

**Priority:** P3 · **Depends on:** nothing blocking — T7a shipped (Recently
Closed); fully actionable now, just not yet scheduled. Blocked for
production on the Cilium + Kyverno module builds.

### T10 — VEX hardening — mechanism DONE, signed authorship deferred — P3

**Mechanism shipped, see Recently closed:** `gate.yaml` now takes an
`IGNOREFILE` param (default `/dev/null`) and applies it via `trivy
convert --ignorefile` — a git-committed, PR-reviewed `.trivyignore`
statically suppresses specific CVE IDs at the same build-time gate that
already re-renders `scan.json`, no live vulnerability-DB call. The
original proposal (`mise run frontend:publish` re-running `trivy image
--vex <referrer>`) turned out not to fit either real tool: `trivy convert`
has no VEX ingestion at all, and the only trivy subcommands that read
OpenVEX (`image`, `sbom`) need a live DB call — which `frontend-publish.sh`
and `gate.yaml` both explicitly do not do. Re-verified against the live
pinned trivy (0.74.0) before landing this, not against the original text.

**Deferred — signed OpenVEX authorship, own follow-up, no current
trigger:** `.trivyignore` is unsigned/unattributed — anyone with commit
access can add a line, same trust model as any other reviewed file, but
not the "same custody as approval/provenance" T10 originally wanted.
Layering `vexctl attest` (signed via a new OpenBao Transit key) on top —
producing the canonical, attributable OpenVEX statement, with a small
script deriving `deploy/frontend/vex/.trivyignore` FROM it — is additive,
not a redo, whenever a real CVE actually needs a signed, attributed
exception. Zero current CRITICAL findings have ever needed a suppression
(checked git history before scoping this session); building the signing
ceremony now would be unused machinery. **Depends on:** nothing blocking,
just no live trigger yet.

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
**Depends on:** nothing blocking — the mechanical pipeline through T8's
build-provenance signing has shipped (Recently Closed); fully actionable
now, just not yet scheduled. (Not cited as "Phase 1-3" — that design doc's
own Phase-3 label still says "Tekton Chains," which T8 shipped without;
logged for the Documentation extraction item, not fixed here.)
