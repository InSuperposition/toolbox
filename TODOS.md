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

**Context:** Surfaced by the 2026-09-06 T5 eng review.
`modules/secret-openbao-local` already has an empty `policies` input ready
for the scoped policy. See `docs/designs/digest-as-source-of-truth.md`
§ Trust boundary and `docs/adr/0004-approval-key-openbao-transit-not-acl.md`.

**Effort:** planning ~1 session; implementation ~1-2d human
**Priority:** P2
**Depends on:** ~~T5 shipped~~ — **UNBLOCKED 2026-09-06.** T5 shipped its
interim auth: `approve.sh` signs with the fnox root `VAULT_TOKEN` and, for a
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
mechanically. `modules/secret-openbao-local` already has an empty `policies`
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
