# TODOS

## Debt

### Scripts-policy audit of the T5 / T5b shell — P1, planning session

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
- `scripts/export-approval-pubkey.sh` — **not in the design**, invented
  during implementation. Its core job is one command (`cosign public-key
  --key openbao://approval-key --outfile ...`). The `openbao://` →
  `hashivault://` → `bao read | jq` fallback chain is unrequested
  complexity. Candidate: a `mise` task one-liner; decide whether any
  fallback is actually warranted (it is a design question, not an
  implementation detail).
- `deploy/frontend/scripts/consume.sh` — the design said "`mise run consume`
  writes the new reference, then `pitchfork restart frontend`" (implying a
  task). It became a 69-line script. The atomic write + real readiness poll
  justify *some* script; check whether pitchfork's own `ready_port` +
  `ready_delay` + a thin task covers it, and whether the readiness reporting
  belongs in the script at all.
- `deploy/frontend/scripts/verify-approval.sh` — error classification is
  done by **string-matching `cosign` stderr** (`*"invalid predicate
  type"*`, `*"accepted signatures do not match threshold"*`, …). Fragile —
  it depends on cosign's unversioned error text (Map-is-not-Territory).
  Check whether `cosign` / `cue` expose distinguishable exit codes, or
  `--output json`, that replace the grep.
- `deploy/frontend/scripts/openbao-preflight.sh` — 4-way state
  discrimination. Design-sanctioned in intent; check the implementation is
  as thin as it can be (is `bao status -format=json` + one authed read the
  minimum, or is there a `bao` subcommand that answers directly?).
- `deploy/frontend/run.sh` — design-named; retry/backoff/signal-traps are
  genuine logic. Lightest-touch review: is the trap/child-process dance the
  simplest correct shape, or does pitchfork have a supervised-`docker`
  primitive?
- `deploy/frontend/tests/helper.bash` — ~190-line bats fixture. Acceptable
  as test infra, but check for duplication and whether `deploy.bats`'s
  docker path should be a separate opt-in file.
- `deploy/frontend/scripts/approve.sh` — design's one sanctioned
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

### How to rotate the T5 `approval-key` (procedure — done once, 2026-09-06)

The first `approval-key` was rotated on 2026-09-06 (commit `bcbb862`)
because it was provisioned in an AI session whose bootstrap output was
transcript-visible. Procedure for any future rotation:
```
mise run openbao-reset            # stops daemon, wipes raft store + fnox VAULT_TOKEN + tfstate
mise run openbao-bootstrap        # fresh key + NEW one-time unseal key (save it out-of-band);
                                  #   auto-runs export-approval-pubkey.sh
git add deploy/frontend/cosign-approval.pub && git commit
```
`fnox.toml` needs no manual fixup — `fnox set` writes the same
`{ provider = "keychain", value = "VAULT_TOKEN" }` the committed file
already has (fixed in `4710857`). Every attestation signed with the old key
stops verifying against the new `cosign-approval.pub` — re-run `mise run
approve` for any image whose approval must persist. `.../rotate` on the
same key would keep old versions verifiable but the *exported* public key
still changes, so a full reset is simpler while nothing real depends on the
key.

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
the OpenBao root token in one person's OS keychain." Anyone with it can
sign any `approvedBy` — there is no cryptographic per-approver identity.
That's acceptable for a solo proof; it is not acceptable once a second
person needs to approve, and building `approve.sh`'s auth twice is waste,
so the shape should be designed before hardening.

**Design lenses:** security (per-identity least privilege, no shared
long-lived secret), DX (a new member from clone to first approval in
minutes, not a runbook), bootstrap (idempotent, works on a fresh machine),
simplicity (an auth method, not a PKI), existing-stack fit (OpenBao auth
backends, fnox, `gh`; check whether Cilium/Kyverno play a role at the
cluster edge later).

**Context:** Surfaced by the 2026-09-06 T5 `/plan-eng-review` (Issues 3+4)
and Codex P2-9. `modules/secret-openbao-local` already has an empty
`policies` input ready for the scoped policy. See the design doc's T5
section ("interim auth") and Resolved Decisions ("Approval trust boundary").

**Effort:** planning ~1 session; implementation ~1-2d human
**Priority:** P2
**Depends on:** ~~T5 shipped~~ — **UNBLOCKED 2026-09-06.** T5 shipped its
interim auth: `approve.sh` signs with the fnox root `VAULT_TOKEN` and, for a
non-local registry, `gh auth token | cosign login` into an isolated
`DOCKER_CONFIG`; `approvedBy` is self-asserted. The `write:packages` scope
on the `gh` token is currently the operator's to arrange (Codex P2-9) — this
session designs the real per-member story.

### T7 Phase-2 (Tekton) — full planning session before any code

**What:** Run `/office-hours` then `/plan-eng-review` on Phase 2 of
`docs/designs/digest-as-source-of-truth.md` before implementing T7a/T7b/T7c.
Phase 2 is split and deferred after T5/T5b; it is NOT implementation-ready.

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
kubeconform/chainsaw harness. T7c = GHCR→zot migration. See the design doc's
"T7 — Phase 2" section and the GSTACK REVIEW REPORT's "T7 REVIEW" entry.

**Effort:** planning ~1-2 sessions; build T7a/T7b/T7c ~3-5d human total
**Priority:** P2
**Depends on:** T5 + T5b shipped and proven

### Confirm the distroless build scans clean, then delete `.trivyignore`

**What:** Run `trivy image --severity CRITICAL --exit-code 1` against the
distroless `cv_frontend` image (pivot D2) with **zero suppressions**. If it
passes, delete `.trivyignore` entirely and remove this entry. If a genuine
residual CRITICAL surfaces, author one OpenVEX statement with real
exploitability evidence + a `last_updated`/re-review date (do **not**
reinstate the old ignore-file lines).

**Why:** Both prior `.trivyignore` entries (CVE-2026-56854 =
`golang.org/x/crypto` in Paketo `npm-install`'s `exec.d` helper;
CVE-2026-59873 = `node-tar` in Node 24.19.0's bundled npm, pulled by Paketo
`node-engine`) are **Paketo-toolchain-only**. Dropping buildpacks (pivot,
2026-09-06) removes the Go helper binary entirely and the bundled npm
(distroless ships none; `cv_frontend` has no `tar` in `package-lock.json`).
The CVEs die at the root, not by suppression — but Codex #8 is right that
this must be *verified* by a clean unsuppressed scan before the file is
deleted, not assumed.

**Context:** See `docs/designs/digest-as-source-of-truth.md` § Pivot (D4)
and the /plan-eng-review + Codex pass of 2026-09-06. `vexctl`
(`aqua:openvex/vexctl`) is already pinned and ready for the residual case;
the full signed-VEX-referrer + consume-side `trivy --vex` enforcement is
design task T10 (post-Chains), not this entry.

**Effort:** S (run one scan, delete one file + this entry)
**Priority:** P1 (part of pivot task T-P0 / T4)
**Depends on:** T4a / T4 (the distroless build existing to scan)

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

**Context:** Pivot D3 (`docs/designs/digest-as-source-of-truth.md` § Pivot)
chose arm64-only deliberately; Codex #2/#10 flagged the index-digest cost
that makes multi-arch a real T5/T5b scope change, not a one-flag switch.

**Effort:** M (build flag is trivial; the T5/T5b index-digest handling is
the real work)
**Priority:** P3
**Depends on:** an actual amd64 deploy or demo target; digest-as-source-of-
truth T5/T5b proven on arm64 first

### Decide public hosting for cv_frontend

**What:** Choose where the actual public `cv_frontend` site lives for a
hiring manager to visit — separate from the demo/proof deploy T5b adds (a
standalone `pitchfork`-supervised Docker container on this dev Mac,
revised from an earlier k8s-namespace plan — see Approach D's "Demo
consumption" section).

**Why:** Anything running on this dev Mac — whether the earlier
k8s-namespace plan or T5b's pitchfork container — is tied to a single
machine staying on, not a reasonable uptime story for a public site.
Candidates worth evaluating: Vercel/Netlify (Remix has first-class
adapters for both), or the eventual `cluster-k0sctl` production cluster
once it exists.

**Context:** Surfaced by an eng-review outside-voice finding (Codex) that
nothing in the design actually deploys/runs `cv_frontend` from a verified
image — T5b closes that gap for proof purposes only, deliberately not for
real public hosting. Read Approach D's "Demo consumption" section of that
design doc for the demo-vs-real-hosting distinction before starting this.

**Effort:** S (research + decision) / M (actual setup)
**Priority:** P2
**Depends on:** digest-as-source-of-truth T5b (demo/proof deploy) proven


### Retrofit vm-orbstack, cluster-k0sctl, secret-openbao to digest-pinning

**What:** Pin the three existing OpenTofu modules' git sources by commit SHA
instead of a mutable tag, matching the digest-as-source-of-truth pattern
proven in `docs/designs/digest-as-source-of-truth.md`.

**Why:** Closes the gap this whole design is about — for the modules that
actually provision production infra, not just the CI pipeline wedge.

**Context:** Explicitly deferred as premise #5 throughout the digest-as-
source-of-truth design session — the wedge proves the pattern on
`ci-build-frontend`'s Tekton pipeline first, deliberately not touching
these three modules. Once Phase 1-2 of that design are proven, apply the
same `ref=<sha>` convention here. Start by reading how
`docs/designs/digest-as-source-of-truth.md` (Premises #2) frames git commit
SHA as the digest-equivalent for git-sourced modules.

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

**Context:** This is `docs/designs/digest-as-source-of-truth.md`'s rejected
Approach C — explicitly deferred because it coupled three previously-
independent concerns (the Tekton module set, `cluster-k0sctl`, Kyverno
mechanics) into one dependency chain and contradicted premise #5. Only
makes sense once `cluster-k0sctl`'s *production* cluster exists for real
(not the OrbStack dev cluster Phases 2-3 use) — building it against the
dev cluster would be enforcing policy on a throwaway environment.

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

**Context:** Explicitly deferred throughout `docs/designs/digest-as-source-
of-truth.md` ("public-trust signing is explicitly deferred... human-
friendly tags and Fulcio/keyless cosign signing come later"). The
mechanical signing (OpenBao Transit, unpublished keys) is intentionally
built first and proven working before spending effort on public trust
infrastructure. Start by reading that design doc's Constraints section on
signing deferral and the Chains section on cosign's keyless mode being a
documented alternative already.

**Effort:** M
**Priority:** P3
**Depends on:** digest-as-source-of-truth Phase 1-3 stable
