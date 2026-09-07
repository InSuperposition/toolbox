# Design: Digest as Source of Truth

## Abstract

A GitOps repo whose stated goal is zero trust, but nothing in it is pinned
by content: modules resolve by mutable git tag, `mise.toml` pins every tool
to `latest`. This design makes the **content digest** the enforced trust
boundary everywhere, and pairs it with an explicit **approval record** on
that digest — a human's signed approve/reject decision — so consumption is
gated on authority, not just on a `@sha256:` in the reference.

The wedge is a build → scan → SBOM → approve → consume pipeline for one
real external consumer, `cv_frontend` (a Remix v3 node server). It is
reviewer-legible in about five minutes: moving a tag cannot change the
deployed bytes, an unapproved-but-valid digest is refused, and every
decision is a signed, verifiable record.

Decisions and their rationale live in [`docs/adr/`](../adr/README.md). Open
work lives in [`../../TODOS.md`](../../TODOS.md).

## Goals

- Every consumed artifact pinned by digest; tags are convenience aliases
  only ([ADR 0001](../adr/0001-digest-is-the-trust-boundary.md)).
- A real, enforced approval boundary on a digest, backed by OpenBao so no
  key file is a single point of failure
  ([ADR 0002](../adr/0002-approval-record-not-digest-alone.md),
  [0004](../adr/0004-approval-key-openbao-transit-not-acl.md)).
- One tool per concern; scripts minimal and tested; declarative first.
- Every piece exercised end-to-end at least once, here, before it is
  called done.

## Constraints

- No home-rolled approval format — use the CNCF/OCI-native mechanism
  (in-toto attestation as an OCI 1.1 referrer), not a bespoke JSON
  convention.
- No plaintext secret in repo or state. The signing key lives in OpenBao
  Transit (`exportable=false`); the consumer verifies against a committed
  *public* key.
- `deploy/frontend/Dockerfile` is the one hand-authored Dockerfile — a
  named carve-out to "no code in configuration files" (two `RUN` lines, no
  shell logic; see CLAUDE.md).
- Interim auth only: `approve.sh` authenticates to OpenBao with the root
  token in `$VAULT_TOKEN` (a `0600` file, ADR 0011) and pushes with a
  call-time `gh` token. Per-member cryptographic identity is a separate
  planning task (`TODOS.md`).
- Public-trust signing (Fulcio/keyless, a published key) is deferred — the
  cosign key is mechanically required, carries no public-trust claim.

## Architecture

```
build ─▶ scan+gate ─▶ evidence referrers ─▶ human approval ─▶ consume gate
```

1. **Build** — `cv_frontend` at a pinned commit SHA is built as a
   digest-pinned distroless Node image from `deploy/frontend/Dockerfile`
   ([ADR 0007](../adr/0007-distroless-dockerfile-not-buildpacks.md)),
   `linux/arm64` only ([ADR 0008](../adr/0008-arm64-only.md)), pushed to
   the registry by digest. Phase 1 runs this as a GitHub Actions workflow
   on a native `ubuntu-24.04-arm` runner
   (`.github/workflows/build-cv-frontend.yml`).

2. **Scan + gate** — `trivy image` produces a JSON scan report and a
   CycloneDX SBOM, both attached to the image digest as OCI 1.1 referrers
   (`trivy` + `oras attach`, not `buildx --sbom` — that emits SPDX embedded
   in the image index, not a Referrers-API referrer). The scan report is
   attached *before* the blocking `--severity CRITICAL --exit-code 1` gate,
   so a reject-worthy image still carries the evidence a human reads. Zero
   suppressions — there is no `.trivyignore`.

3. **Evidence referrers** — the digest ends up carrying a CycloneDX SBOM
   and a trivy scan report (and, from Phase 3, a Tekton Chains provenance
   attestation). These are evidence a reviewer reads; none of them is the
   gate.

4. **Human approval** — `mise run approve -- <registry/repo@sha256:...>`
   (`deploy/frontend/scripts/approve.sh`) runs an OpenBao preflight
   (`openbao-preflight.sh` — distinguishes unreachable / sealed /
   unauthorized / missing-key, exit 3), pulls and summarises the evidence,
   prompts approve/reject + a reason, `cue vet`s the predicate against
   `#Predicate` in `verdict-approved.cue`, then signs it as an in-toto
   attestation:

   ```
   cosign attest --predicate <file> --type <URI> \
     --key openbao://approval-key \
     --use-signing-config=false --tlog-upload=false <ref>
   ```

   Both flags are required — cosign 3.1.3 otherwise fetches a TUF signing
   config and uploads to the public Rekor tlog. The attestation is stored
   as an `application/vnd.dev.sigstore.bundle.v0.3+json` referrer. Every
   completed decision is signed — approve *and* reject, never silent —
   except an EOF / Ctrl-C / empty prompt, which writes nothing. `approve.sh`
   prints the new attestation's own digest; that digest is the selection
   key ([ADR 0006](../adr/0006-approval-selection-is-attestation-digest-pin.md)).

5. **Consume gate** —
   `mise run consume -- <ref> <attestation-digest>`
   (`deploy/frontend/scripts/consume.sh`) calls the shared
   `verify-approval.sh`, which fetches *that specific attestation*, verifies
   its signature against the committed `deploy/frontend/cosign-approval.pub`
   ([ADR 0005](../adr/0005-consume-verifies-against-committed-pubkey.md)),
   checks the subject digest and predicate type with `cosign
   verify-blob-attestation`, then `cue vet`s the statement against
   `#ApprovedStatement` (verdict must be `approved`). Exit 0 = valid and
   approved; exit 1 = terminal failure with a distinct message (bad
   signature / wrong subject / wrong predicate type / verdict rejected /
   bad schema); exit 3 = retryable (attestation or bundle could not be
   pulled). `cosign verify-attestation --policy` is deliberately **not**
   used — it fails if *any* attestation of the type on the image fails the
   policy, which the digest pin avoids.

### The approval schema

`deploy/frontend/verdict-approved.cue` is one file with two definitions:
`#Predicate` is permissive (both verdicts) for the sign-side `cue vet`;
`#ApprovedStatement` wraps the whole in-toto statement and pins `verdict:
"approved"` for the consume-side check. CUE is a schema language (satisfies
"schemas required for core functionality") and one file avoids maintaining
the permissive and strict shapes separately. There is no JSON Schema.

### Trust boundary

Possession of the OpenBao-held `approval-key` private half — never present
in a Pipeline's cluster environment — is what distinguishes a real approval
referrer from the automated SBOM/provenance ones
([ADR 0004](../adr/0004-approval-key-openbao-transit-not-acl.md)).
Registry ACLs and k8s RBAC were verified insufficient for this. The
consumer trusts only a referrer that verifies against the committed public
key; mere referrer presence is not enough.

**Interim-auth honesty:** today "the private key" means "the OpenBao root
token in the OS keychain" — anyone with it can sign any `approvedBy`.
`approvedAt` is self-asserted (no trusted timestamp) — an audit field, never
a trust input. Per-member identity is a `TODOS.md` planning task.

## File layout

Extends the repo's own Repo Role pattern (`modules/*` reusable, a root
composition applies them) to Tekton content, mirroring
[tektoncd/catalog](https://github.com/tektoncd/catalog)'s kind-first,
versioned convention for the reusable pieces:

```
modules/task-<builder>-build/        # reusable Task: build an app image (builder TBD — TODOS.md T7a)
modules/task-trivy-scan/             # reusable Task: scan, emit CycloneDX SBOM, block on CRITICAL
modules/task-oras-attach/            # reusable Task: attach an OCI referrer to a digest
modules/pipeline-build-scan-approve/ # reusable Pipeline: build -> scan+SBOM -> attach SBOM
                                     #   ("approve" is the Pipeline's PURPOSE — approval runs outside Tekton)
modules/secret-openbao-local/        # reusable: Transit engine + N signing keys + N policies + rendered openbao.hcl
environments/local/                  # the ONE instance of secret-openbao-local (main.tf)
deploy/frontend/                     # the per-consumer instantiation for cv_frontend:
  Dockerfile, Dockerfile.dockerignore   #   the distroless build (ADR 0007)
  verdict-approved.cue                   #   the approval schema
  cosign-approval.pub                    #   committed public key — what consume verifies against (ADR 0005)
  scripts/approve.sh                     #   mise run approve — evidence -> human decision -> signed attestation
  scripts/verify-approval.sh             #   the shared verify seam (consume.sh, run.sh); no OpenBao
  scripts/consume.sh                     #   mise run consume — verify + record + restart + readiness check
  scripts/openbao-preflight.sh           #   4-way OpenBao state check, exit 3
  run.sh                                 #   pitchfork frontend daemon entrypoint (ADR 0009)
  tests/*.bats + tests/helper.bash       #   the test matrix
```

OpenBao/Transit is not per-consumer: `approval-key` and a future
`chains-provenance-key` are two entries in one `transit_keys` list in
`environments/local/main.tf`, not two instances. `pitchfork.toml` stays at
the repo root (pitchfork only discovers the nearest one searching *upward*);
its `openbao` daemon's `dir = "environments/local"` points `bao server` at
the right cwd. `deploy/frontend/` only ever names a key
(`openbao://approval-key`) — it never provisions OpenBao. See
`environments/local/README.md` for the bootstrap/reset/snapshot runbook.

**No embedded scripts in Tekton YAML** — every Task step is a single pinned
CLI invocation via Kubernetes' native `command`/`args`. `approve.sh` (the
one place with real go/no-go logic) is not part of any Task or Pipeline —
it is a plain script the repo owner runs, exactly as a required-reviewer
click is "manual" in any CI system.

## Phasing

Sequenced so each phase adds one new moving part and ships/tests
independently (Gall's Law). The full sequencing lives in `TODOS.md`.

- **Phase 1 — shipped (T1–T6).** `mise.toml` pinned; the distroless build
  runs as a GitHub Actions workflow to GHCR; `trivy` scan + CRITICAL gate +
  CycloneDX SBOM + scan-report referrers; OpenBao Transit (`approval-key`)
  provisioned by `modules/secret-openbao-local` + `environments/local/`,
  supervised by `pitchfork`; `approve.sh` / `verify-approval.sh` /
  `consume.sh` proven live against real GHCR; the demo consumer is a local
  `pitchfork` container ([ADR 0009](../adr/0009-demo-consumer-is-local-container-not-k8s.md));
  `mise run local:openbao:snapshot` / `openbao-snapshot-restore` for backup.
  Registry is **GHCR** — hosted, zero-ops, unmetered on public repos.

- **Phase 2 — Tekton (deferred, T7a/T7b/T7c).** Move the build/scan/attach
  path into reusable Tekton Tasks + a Pipeline on `orb start k8s`
  ([ADR 0003](../adr/0003-tekton-pipelines-on-orbstack-k8s.md)); build the
  kubeconform + chainsaw test harness; migrate GHCR → `zot`. The in-cluster
  daemonless builder (BuildKit-k8s-driver vs a kaniko fork vs buildah) is
  an open spike. Each sub-task needs its own planning session — `TODOS.md`.

- **Phase 3 — Tekton Chains (T8).** Install Chains; a second OpenBao Transit
  key (`chains-provenance-key`) with an access policy denying it
  `approval-key`; automatic signed SLSA provenance per build. First task:
  widen OpenBao's listener past loopback with real TLS so an in-cluster pod
  can reach it.

- **Phase 4 — bisect-safety gate (T9).** An `hk.pkl`-declared,
  `mise run check`-invoked rebuild-in-isolation check over a pushed commit
  range, run CI-side (async — a full isolated rebuild per commit is too
  slow for a pre-push hook). Independent of Phases 1–3.

## Negative space (deliberately not used)

- **Kyverno admission-time enforcement** — couples the Tekton set,
  `cluster-k0sctl`, and Kyverno mechanics into one chain; contradicts the
  "no production cluster in this wedge" premise. Tracked: `TODOS.md`.
- **Paketo buildpacks** — removed ([ADR 0007](../adr/0007-distroless-dockerfile-not-buildpacks.md)).
- **apko / melange** — fully declarative image build; an innovation-token
  overspend for one npm app.
- **Multi-arch builds** — `linux/arm64` only ([ADR 0008](../adr/0008-arm64-only.md));
  deferred to a real amd64 consumer.
- **`buildx --sbom` / `--provenance`** — emit SPDX in the image index, not a
  Referrers-API referrer.
- **Public-trust signing** (Fulcio/keyless, a published key) — the cosign
  key stays mechanically-required-only. Tracked: `TODOS.md`.
- **Pipelines-as-Code webhook triggering** — the pipeline runs on-demand;
  webhook triggering is a later addition, not required to prove the design.
- **The production `secret-openbao` module** — Phase 1's OpenBao is a
  local, `pitchfork`-supervised dev process, explicitly not that module.
- **Ephemeral debug container** — a throwaway pod/shell for interactive
  build debugging; a deliberate omission, revisit when needed.

## Phase 1 data flow

```
GitHub Actions (public repo, unmetered)          Local (repo owner's machine)
┌────────────────────────────────────┐           ┌───────────────────────────┐
│ checkout cv_frontend@pinned-SHA    │           │ pitchfork: openbao        │
│            │                       │           │  (raft storage)           │
│            ▼                       │           │   Transit: approval-key   │
│ docker buildx build                │           │     └─ never leaves       │
│   --platform linux/arm64 --push    │           │        OpenBao            │
│   (deploy/frontend/Dockerfile)     │           └───────────────────────────┘
│            │  digest ◀ meta.json   │                        ▲
│            ▼                       │                        │ cosign attest
│ trivy scan --format json          │                        │ --key openbao://
│   └─ oras attach scan.json         │                        │   approval-key
│            ▼                       │            ┌───────────┴───────────────┐
│ trivy --format cyclonedx          │            │ mise run approve -- <ref> │
│   └─ oras attach sbom.cdx.json     │            │  show SBOM + scan report  │
│            ▼                       │            │  human: approve / reject  │
│ trivy image --severity CRITICAL   │            │  ALWAYS signs, either way  │
│   --exit-code 1   (blocking, LAST) │◀───────────┤  prints attestation digest│
└─────────────┬──────────────────────┘            └───────────────────────────┘
              │ image + SBOM + scan.json + approval referrers
              ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │ mise run consume -- <registry/repo@sha256:...> <attestation-dig> │
   │   verify-approval.sh:  fetch THAT attestation (by digest)         │
   │     cosign verify-blob-attestation --bundle <blob>                │
   │       --key cosign-approval.pub  (committed; NO OpenBao call)     │
   │       --type <URI> --check-claims --insecure-ignore-tlog          │
   │     then: cue vet <statement> -d '#ApprovedStatement'             │
   │       ├── valid sig + approved ──▶ exit 0                          │
   │       ├── valid sig + rejected ──▶ exit 1  "verdict: rejected"     │
   │       ├── bad / wrong-subject / wrong-type ──▶ exit 1 (named)      │
   │       ├── not found / registry down ──▶ exit 3 (retryable)         │
   │       └── tag-only reference ──▶ exit 2                            │
   └─────────────────────────────────────────────────────────────────┘
```

## Failure modes

| Codepath | Realistic failure | Handling |
|---|---|---|
| Dockerfile build | `npm ci` fails (lock drift, esbuild postinstall on arm64) | `docker build` non-zero, workflow fails; `tests/*.bats` build against a clean checkout |
| Distroless runtime | image builds but crashes at start (Remix RC crash, missing writable cache dir as non-root) | container exits non-zero; readiness check on :44100 fails and reports truthfully |
| Distroless: no shell | a later script assumes `docker exec … sh` | fails immediately; design uses HTTP readiness, not `docker exec` |
| trivy scan | CRITICAL finding (zero suppressions) | blocks *after* the scan-report referrer is attached |
| GHCR push | `GITHUB_TOKEN` missing `packages: write` | push fails loudly; documented, not tested |
| `mise run approve` | OpenBao unreachable / sealed / unauthorized / missing-key | `openbao-preflight.sh` distinguishes all four, exit 3, names the fix |
| `mise run approve` | Ctrl-C / EOF / empty at the prompt | no signed record written, clean abort |
| `mise run approve` | `cosign attest` signs but the registry push fails | read-back check fails loudly, non-zero; no false "approved" |
| `mise run consume` / launch re-verify | attestation missing / bad sig / wrong subject / verdict rejected | `verify-approval.sh` exit 1, distinct stderr per case |
| launch re-verify | GHCR transient failure | `verify-approval.sh` exit 3 → `run.sh` bounded retry + backoff → visible stopped state, never a hang |
| `verify-approval.sh` | OpenBao down | not applicable — consume never touches OpenBao |
| OpenBao Transit | raft store lost | past approvals still verify (pubkey in-repo); `openbao-snapshot-restore` restores signing ability |

---

Decisions and rationale: [`docs/adr/`](../adr/README.md). Open work:
[`TODOS.md`](../../TODOS.md). Revise this document in place, present tense —
do not strike-through; record a superseding ADR instead.
