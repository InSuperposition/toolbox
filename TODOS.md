# TODOS

## Infrastructure

### Decide public hosting for cv_frontend

**What:** Choose where the actual public `cv_frontend` site lives for a
hiring manager to visit — separate from the demo/proof Deployment this
design adds to a `cv-frontend` namespace on the OrbStack dev cluster.

**Why:** That dev cluster is explicitly scoped throughout `docs/designs/
digest-as-source-of-truth.md` as dev/CI-only, tied to a single Mac staying
on and OrbStack staying up — not a reasonable uptime story for a public
site. Candidates worth evaluating: Vercel/Netlify (Remix has first-class
adapters for both), or the eventual `cluster-k0sctl` production cluster
once it exists.

**Context:** Surfaced by an eng-review outside-voice finding (Codex) that
nothing in the design actually deploys/runs `cv_frontend` from a verified
image — the demo namespace (Phase 2) closes that gap for proof purposes
only, deliberately not for real public hosting. Read the Phase 2 section
of that design doc for the demo-vs-real-hosting distinction before
starting this.

**Effort:** S (research + decision) / M (actual setup)
**Priority:** P2
**Depends on:** digest-as-source-of-truth Phase 2 (demo namespace) proven


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

### Migrate OpenBao off the file storage backend before v2.7.0

**What:** Run `bao operator migrate` to move `deploy/cv-frontend`'s local
OpenBao process off the `file` storage backend to a supported one (e.g.
`raft`/integrated storage) before upgrading past OpenBao v2.6.x.

**Why:** Starting the pitchfork-supervised OpenBao process (T3) surfaced a
live warning not previously known when the design was written: `storage.
file: the file physical backend is deprecated; use bao operator migrate to
move to a supported storage backend by v2.7.0`. `openbao.hcl` pins `file`
today deliberately (matches the design doc's original T3 spec verbatim),
but that spec predates this deprecation notice — this is a real,
version-pin-relevant gap the design didn't anticipate, not a hypothetical.

**Context:** Discovered 2026-09-05 during T3's live smoke test (`pitchfork
start openbao`, real init/unseal/apply cycle against OpenBao 2.6.2).
Migrating changes the storage stanza in `deploy/cv-frontend/openbao/
openbao.hcl` and the daemon's data layout — do this deliberately, with a
tested backup first (see T6 in `docs/designs/digest-as-source-of-truth.md`,
also not yet built), not as a surprise side effect of a routine `mise
install` version bump.

**Effort:** S
**Priority:** P1 (blocks safely bumping `openbao` past 2.6.x in mise.toml)
**Depends on:** T6 (OpenBao storage backup/restore) landing first
