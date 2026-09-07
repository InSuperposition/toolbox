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
- **T5** (approve) — built. `scripts/approve.sh`,
  `scripts/verify-approval.sh`, `scripts/openbao-preflight.sh`,
  `verdict-approved.cue`, `cosign-approval.pub`. See "Approve" below.
- **T5b** (verify + local deploy) — built. `scripts/consume.sh`, `run.sh`,
  `pitchfork.toml` `[daemons.frontend]`. See "Consume + deploy" below.

## Approve (T5)

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
key — record it.

Because the consumer pins one attestation by digest, a later reject — or a
validly-signed reject sitting next to a good approval on the same image —
does not change what an already-pinned consumer sees. A mistaken reject is
just an unselected record; a re-approval is a new selectable one.

## Consume + deploy (T5b)

The consumer of an approved image, here, is a local
`pitchfork`-supervised Docker container on the dev Mac — a demo/proof of
the pipeline mechanism, not where a real site lives.

```
mise run consume -- ghcr.io/insuperposition/cv-frontend@sha256:<digest> sha256:<attestation-digest>
```

`scripts/consume.sh`:

1. Runs `scripts/verify-approval.sh` (below). If it fails, **nothing
   changes** — the state file and the running container are left as they
   were, and it exits non-zero.
2. Atomically (temp + rename) records the full image reference and the
   attestation digest in `current-image.txt` (git-ignored, per-machine).
3. `pitchfork restart frontend`.
4. Polls `http://127.0.0.1:44100/` and reports the **real** result — HTTP
   code if it comes up, a "did NOT come ready" message (exit 1) if it
   doesn't. `cv_frontend` has a known Remix v3 runtime crash, so this step
   failing for the real app is expected; T5b proves the pipeline, not the
   app.

`run.sh` is the pitchfork `frontend` daemon's entrypoint (a **fixed**
indirection — never repoint it; that would let a deploy rewrite pitchfork's
own config). On every launch it re-reads `current-image.txt`, **re-verifies
the approval** (not just at consume time), then runs the container in the
foreground with the traps that stop it cleanly on pitchfork's signal (no
orphan). Bounded retries with backoff on a *retryable* verify failure
(registry unreachable — `verify-approval.sh` exit 3), then a visible
stopped state; a *terminal* failure (bad signature / verdict rejected —
exit 1) stops at once. Works on a cold, non-interactive start — the image
and its referrers are pulled anonymously, no inherited credentials.

Known gap, named not solved: launch-time verification does not stop an
**already-running** container whose image is rejected afterwards. That
needs a separate watch, deferred.

`mise run verify-approval` runs just the check, no deploy.

### verify-approval.sh — the shared seam

`scripts/verify-approval.sh <ref> <attestation-digest>` is what
`mise run consume`, `run.sh`, and (later) T10's VEX check all call. It
fetches **that specific attestation**, verifies its signature against the
committed `cosign-approval.pub`, checks the subject digest and predicate
type with `cosign verify-blob-attestation`, then `cue vet`s the statement
against `#ApprovedStatement` (verdict must be `approved`).

- Exit 0 — valid and approved.
- Exit 1 — **terminal**: bad signature / wrong subject / wrong predicate
  type / verdict rejected / bad schema. Re-running won't change it.
- Exit 3 — **retryable**: the attestation or its bundle blob couldn't be
  pulled (not found yet / registry unreachable). `run.sh` retries this.
- Exit 2 — bad arguments / missing public key.

### Why consume never touches OpenBao

`verify-approval.sh` verifies against `cosign-approval.pub`, exported once
from `openbao://approval-key` at bootstrap and committed here. Losing the
OpenBao raft store stops *future* signing but does not invalidate any past
approval. Only `approve.sh` needs OpenBao up and unsealed.

After any Transit key rotation the exported public key changes — re-run
`mise run openbao-bootstrap` (or `mise run export-approval-pubkey`) and
re-commit `cosign-approval.pub`, or consume verifies new signatures against
a stale key.

### Interim auth (a full design is pending)

T5 ships an interim auth good for a solo operator. The full multi-member
design — per-member OpenBao identity, per-member registry auth, a clean
`git clone → mise run approve` bootstrap — is its own planning session
(TODOS.md "Auth + multi-member DX", gated on T5 shipping interim first).

Interim, `approve.sh`:

- authenticates to OpenBao with the **root token** in `$VAULT_TOKEN`
  (`mise [env]` reads the `0600` `root.token` file, ADR 0011). Anyone
  holding it can sign any `approvedBy` value —
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
| `scripts/verify-approval.sh` | the shared verify seam (consume.sh, run.sh); no OpenBao. Exit 0/1/2/3 — see above |
| `scripts/consume.sh` | `mise run consume` — verify, record `current-image.txt`, restart the daemon, readiness-check |
| `run.sh` | pitchfork `frontend` daemon entrypoint — re-verify + run the container in the foreground |
| `scripts/openbao-preflight.sh` | distinguishes unreachable / sealed / unauthorized / missing-key, exit 3 |
| `verdict-approved.cue` | `#Predicate` (permissive, sign side) + `#ApprovedStatement` (verdict==approved, consume side) |
| `cosign-approval.pub` | committed public half of `openbao://approval-key` — what verify checks against; written by `mise run export-approval-pubkey` (one `cosign public-key` line; `mise run openbao-bootstrap` also writes it), re-run + commit after a Transit key rotation |
| `current-image.txt` | git-ignored, per-machine — the image ref + attestation digest `run.sh` deploys |
| `tests/{approve,verify-approval,deploy}.bats`, `tests/helper.bash` | the test matrix (local zot + a throwaway cosign key via the `TOOLBOX_APPROVE_KEY` seam; `deploy.bats`'s container cases also need docker) |

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

## Why a local container, not a k8s Deployment

This reopened an earlier "locked" decision (a `cv-frontend` k8s namespace +
`kubectl apply` on OrbStack's cluster) — see
`docs/adr/0009-demo-consumer-is-local-container-not-k8s.md` for the full
reasoning. `orb start k8s` still exists and still hosts Tekton
Pipelines/Chains (Phase 2+) — that dependency is unaffected; only where the
*app itself* runs changed.

This proves the pipeline mechanism (right image pulled, container starts,
HTTP readiness checked and its real result reported truthfully) — not
`cv_frontend`'s own correctness. `cv_frontend` currently crashes at
runtime with a Remix v3 `IMPORT_OUTSIDE_FILE_MAP` error (a different repo's
bug); the readiness check reports that truthfully and `consume.sh` exits
non-zero, but the image is still recorded and the daemon still restarted —
the mechanism worked.
