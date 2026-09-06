# deploy/frontend

## Abstract

Per-consumer instantiation for the digest-as-source-of-truth pipeline's
`cv_frontend` consumer (CLAUDE.md § Module Structure & Naming's Tekton
exception: PipelineRun binding + consumer-specific scripts/tests live
here; directory named `frontend`, not `cv-frontend` — this holds
whatever frontend app is the pipeline's consumer, not tied to the `cv_`
name forever).

- **T4** (GitHub Actions build/scan/SBOM) — built, CI-green
  (`.github/workflows/build-cv-frontend.yml`).
- **T5** (approve / consume) — built. `scripts/approve.sh`,
  `scripts/verify-approval.sh`, `scripts/openbao-preflight.sh`,
  `verdict-approved.cue`, `cosign-approval.pub`. See below.
- **T5b** (local pitchfork-supervised deploy) — not yet built.

## Approve / consume (T5)

### The model

The build (T4) produces an image digest and attaches two evidence
referrers to it — a CycloneDX SBOM and a full trivy scan report. A human
reads that evidence and signs a decision:

```
mise run approve -- ghcr.io/insuperposition/cv-frontend@sha256:<digest>
```

`approve.sh` runs an OpenBao preflight, pulls and summarises the evidence,
prompts for `approve` / `reject` + a reason, `cue vet`s the predicate
against `#Predicate` in `verdict-approved.cue`, then signs it as an
in-toto attestation over the image digest with `openbao://approval-key`
(OpenBao Transit — key material never leaves OpenBao). It **always** writes
a signed record for either verdict — never silent — **except** when the
operator aborts at the prompt (EOF / Ctrl-C / empty), which writes nothing.

It prints the new attestation's own digest. That digest is the selection
key. The consumer pins it:

```
mise run consume -- ghcr.io/insuperposition/cv-frontend@sha256:<digest> sha256:<attestation-digest>
```

`verify-approval.sh` (what `mise run consume` calls, and what T5b's
`run.sh` and T10's VEX check will also call) fetches **that specific
attestation**, verifies its signature against the committed
`cosign-approval.pub`, checks the subject digest and predicate type with
`cosign verify-blob-attestation`, then `cue vet`s the statement against
`#ApprovedStatement` (verdict must be `approved`). Exit 0 means valid and
approved; exit 1 prints a distinct line per failure (not found / bad
signature / wrong subject / wrong predicate type / verdict rejected / bad
schema).

Because the consumer pins one attestation by digest, a later reject — or a
validly-signed reject sitting next to a good approval on the same image —
does not change what an already-pinned consumer sees. A mistaken reject is
just an unselected record; a re-approval is a new selectable one.

### Why consume never touches OpenBao

`verify-approval.sh` verifies against `cosign-approval.pub`, exported once
from `openbao://approval-key` at bootstrap and committed here. Losing the
OpenBao raft store stops *future* signing but does not invalidate any past
approval. Only `approve.sh` needs OpenBao up and unsealed.

After any Transit key rotation the exported public key changes — re-run
`mise run openbao-bootstrap` (or re-export) and re-commit
`cosign-approval.pub`, or consume verifies new signatures against a stale
key.

### Interim auth (a full design is pending)

T5 ships an interim auth good for a solo operator. The full multi-member
design — per-member OpenBao identity, per-member registry auth, a clean
`git clone → mise run approve` bootstrap — is its own planning session
(TODOS.md "Auth + multi-member DX", gated on T5 shipping interim first).

Interim, `approve.sh`:

- authenticates to OpenBao with the **root token** from fnox
  (`VAULT_TOKEN`). Anyone holding it can sign any `approvedBy` value —
  there is no per-approver cryptographic identity yet, so `approvedBy` is
  self-asserted audit text.
- pushes the attestation to GHCR with a **call-time `gh auth token`**. That
  token needs the `write:packages` scope (and, for an org, SSO authorised).
  Check with `gh auth status`; if the scope is missing,
  `gh auth refresh -h github.com -s write:packages`.
- a `127.0.0.1:*` / `localhost:*` registry reference is treated as a local
  http dev registry — plain http, no auth (used by the bats tests).

`approvedAt` is self-asserted (no trusted timestamp) — audit metadata only,
never a trust input.

### Files

| File | Role |
|---|---|
| `scripts/approve.sh` | `mise run approve` — evidence → human decision → signed attestation |
| `scripts/verify-approval.sh` | `mise run consume` — the shared consume-side gate; no OpenBao |
| `scripts/openbao-preflight.sh` | distinguishes unreachable / sealed / unauthorized / missing-key, exit 3 |
| `verdict-approved.cue` | `#Predicate` (permissive, sign side) + `#ApprovedStatement` (verdict==approved, consume side) |
| `cosign-approval.pub` | committed public half of `openbao://approval-key` — what consume verifies against; written by `../../scripts/export-approval-pubkey.sh` (also `mise run export-approval-pubkey`), re-run after a key rotation |
| `tests/approve.bats`, `tests/verify-approval.bats`, `tests/helper.bash` | the test matrix (local zot + a throwaway cosign key via the `TOOLBOX_APPROVE_KEY` seam) |

## Where OpenBao/Transit went

T3's OpenBao Transit engine + `approval-key` is **not** owned by this
directory. It lives in `environments/local/` (`modules/
secret-openbao-local` + `environments/local/main.tf`; `pitchfork.toml`
itself stays at repo root for daemon discoverability) because it's shared
infra, not a frontend-specific concern — T8 (Phase 3) adds a second
Transit key (`chains-provenance-key`) to the same instance for a
repo-wide concern (Tekton Chains provenance), not another per-consumer
copy. See `environments/local/README.md` for the OpenBao bootstrap steps.

`approve.sh` signs via `openbao://approval-key` — that key name, not a path
into this directory.

## Local deploy (T5b, not yet built)

The approved digest runs as a standalone `pitchfork`-supervised Docker
container on this dev Mac — not a Kubernetes Deployment. `pitchfork.toml`
(repo root) gets a `[daemons.frontend]` entry pointing at `run.sh` here;
`run.sh` reads the currently-approved image reference and its attestation
digest from `current-image.txt` (git-ignored, written atomically by `mise
run consume`), re-verifies the pinned approval via `scripts/
verify-approval.sh` (shared with `mise run consume` itself), then
`docker run --rm --platform linux/arm64 -p 44100:44100 <image>` in the
foreground — pitchfork is the sole process supervisor, no
`--restart=always` competing with it.

This deliberately reopened an earlier "locked" design decision (a
`cv-frontend` k8s namespace + `kubectl apply` on OrbStack's cluster) —
see `docs/designs/digest-as-source-of-truth.md`'s Approach D for the full
reasoning. `orb start k8s` still exists and still hosts Tekton
Pipelines/Chains (Phase 2+, T7/T8) — that dependency is unaffected; only
where the *app itself* runs changed.

T5b proves the pipeline mechanism (right image pulled, container starts,
HTTP readiness checked and its real result reported truthfully) — not
`cv_frontend`'s own correctness. `cv_frontend` currently crashes at
runtime with a Remix v3 `IMPORT_OUTSIDE_FILE_MAP` error (found during
T4a's dry run, a different repo's bug) — T5b's acceptance criteria
account for this explicitly, they don't block on it being fixed.
