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
- Interim auth only: `attestation-sign.sh` authenticates to OpenBao with
  the root token in `$VAULT_TOKEN` (a `0600` file, ADR 0011) and pushes with
  a call-time `gh` token. Per-member cryptographic identity is a separate
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
   attached (`scan-attach` Task) *before* the blocking gate (`gate` Task —
   `trivy convert --severity=CRITICAL --exit-code=2` re-reading that same
   `scan.json`), so a reject-worthy image still carries the evidence a
   human reads and the gate verdict cannot drift from it. `--exit-code=2`,
   not 1: trivy returns 1 for both a match and an internal error, so 2
   marks the real CRITICAL verdict and 1 stays "gate errored". Zero
   suppressions — there is no `.trivyignore`.

3. **Evidence referrers** — the digest ends up carrying a CycloneDX SBOM
   and a trivy scan report (and, from Phase 3, a Tekton Chains provenance
   attestation). These are evidence a reviewer reads; none of them is the
   gate.

4. **Human approval** — `mise run attestation:sign -- <registry/repo@sha256:...>`
   (`attestation/scripts/attestation-sign.sh`) runs an OpenBao preflight
   (`attestation/scripts/openbao-preflight.sh` — distinguishes unreachable /
   uninitialised / sealed / unauthorized / missing-key, exit 3), pulls and
   summarises the evidence, prompts approve/reject + a reason, `cue vet`s the
   predicate against `#Predicate` in `attestation/verdict-approved.cue`, then
   signs it as an in-toto attestation:

   ```
   cosign attest --predicate <file> --type <URI> \
     --key openbao://approval-key \
     --use-signing-config=false --tlog-upload=false <ref>
   ```

   Both flags are required — cosign 3.1.3 otherwise fetches a TUF signing
   config and uploads to the public Rekor tlog. The attestation is stored
   as an `application/vnd.dev.sigstore.bundle.v0.3+json` referrer, carrying
   the `dev.sigstore.bundle.content` + `dev.sigstore.bundle.predicateType`
   manifest annotations cosign's own discovery (`cosign.GetBundles`) filters
   on — so an admission verifier that discovers by image reference, not by a
   pinned digest (Kyverno, [ADR 0020](../adr/0020-imagevalidatingpolicy-on-the-dev-reference-cluster.md)),
   finds it. `attestation-verify.sh` is handed the digest and never reads
   those annotations. Every completed decision is signed — approve *and*
   reject, never silent —
   except an EOF / Ctrl-C / empty prompt, which writes nothing.
   `attestation-sign.sh` prints the new attestation's own digest; that
   digest is the selection key ([ADR 0006](../adr/0006-approval-selection-is-attestation-digest-pin.md)).

5. **Consume gate** —
   `mise run frontend:deploy -- <ref> <attestation-digest>`
   (`deploy/frontend/scripts/frontend-deploy.sh`) reaches the shared
   `attestation/scripts/attestation-verify.sh` through the
   `TOOLBOX_ATTESTATION_VERIFY` env seam (`lib/frontend.sh`; the one allowed
   `deploy/frontend ▶ attestation` edge, ADR 0013). It fetches *that specific
   attestation*, verifies its signature against the committed
   `attestation/cosign-approval.pub`
   ([ADR 0005](../adr/0005-consume-verifies-against-committed-pubkey.md)),
   checks the subject digest and predicate type with `cosign
   verify-blob-attestation` (one call — its wording is unversioned, so a
   failure there is one generic terminal line plus cosign's own output in
   the log, never re-classified by parsing that text), then `cue vet`s the
   statement against `#ApprovedStatement` (verdict must be `approved`).
   Exit 0 = valid and approved; exit 1 = terminal failure ("attestation
   verification failed", or the CUE-derived "verdict: rejected"); exit 3 =
   retryable (attestation or bundle could not be pulled). `cosign
   verify-attestation --policy` is deliberately **not**
   used — it fails if *any* attestation of the type on the image fails the
   policy, which the digest pin avoids.

   The **in-cluster** consumer reaches the same seam:
   `mise run frontend:publish -- <ref> <attestation-digest> <rev>`
   (`deploy/frontend/scripts/frontend-publish.sh`, ADR 0021) verifies the
   pinned attestation the identical way, then renders the Timoni module
   (ADR 0019) and `flux push`es the manifests for Flux to reconcile into ns
   `frontend` — where Kyverno's `ImageValidatingPolicy` re-verifies the
   approval attestation at pod admission (Plan B K1,
   [ADR 0020](../adr/0020-imagevalidatingpolicy-on-the-dev-reference-cluster.md)).
   Two gates, one contract: the operator step and the admission webhook both
   demand a digest-pinned "approved" attestation signed by the approval key.

### The approval schema

`attestation/verdict-approved.cue` is one file with two definitions:
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
token in a `0600` file" (`$OPENBAO_STATE_DIR/root.token`, ADR 0011 — no
keychain, no `fnox`) — anyone with it can sign any `approvedBy`.
`approvedAt` is self-asserted (no trusted timestamp) — an audit field, never
a trust input. Per-member identity is a `TODOS.md` planning task.

## File layout

Each top-level concern owns its files and declares which other concerns it
may name (`docs/designs/repo-structure.md`, ADR 0012/0013). The reusable
Tekton definitions live in a `ci/` concern (T7a–T7b3 built the Pipeline).
They are versioned by content digest, not by path (ADR 0014). Since the T7c
pre-plan (ADR 0015): local Flux reconciles the defs from a `GitRepository`
via plain `Kustomization` CRs — the declarative interim that replaced the
hand-`kubectl apply`; the digest-pinned OCI-bundle form (ADR 0014) stays
the eventual target. The Flux `Kustomization` CRs live in
`environments/local/flux/`; each reconciled `ci/` path carries its own
`kustomization.yaml` inventory so the recursive kustomize walk never
reaches `ci/tests/**`.

```
attestation/                         # the consumer-agnostic sign+verify seam (ADR 0013)
  verdict-approved.cue                  #   the approval schema (#Predicate / #ApprovedStatement)
  cosign-approval.pub                   #   committed public key — what verify checks against (ADR 0005)
  scripts/attestation-sign.sh           #   mise run attestation:sign  — evidence -> human decision -> signed attestation
  scripts/attestation-verify.sh         #   mise run attestation:verify — the shared verify seam; no OpenBao
  scripts/openbao-preflight.sh          #   5-state OpenBao check (unreachable/uninitialised/sealed/unauthorized/missing-key), exit 3
  scripts/lib/attestation.sh            #   shared: predicate type, digest-ref check, local-registry detection
  scripts/tests/*.bats + helper.bash

deploy/frontend/                     # the per-consumer instantiation for cv_frontend:
  Dockerfile, Dockerfile.dockerignore   #   the distroless build (ADR 0007)
  pipelinerun.cue                       #   T7b3 — the per-consumer PipelineRun, plain CUE (NOT a Timoni module); #image.manifests.{host,inCluster} for M3
  timoni/                               #   M3/ADR 0019 — the cv_frontend Timoni module (Deployment/Service/SA, typed #Config, full-digest image constraint) + tests/
  timoni.lock                           #   M3 — D_img + D_att + D_man (the rendered-manifest artifact digest); re-pinned in a PR per publish
  k8s/namespace.yaml                    #   M3 — the `frontend` namespace: PSA restricted + the `toolbox.dev/cv-frontend: approval-enforced` label K1's policy matches
  scripts/frontend-build.sh            #   T7b3 — mise run frontend:build — render pipelinerun.cue + create + watch + print digest + attestation:sign line
  scripts/frontend-deploy.sh            #   mise run frontend:deploy — verify + record + restart + readiness check (the pitchfork path, ADR 0009)
  scripts/frontend-publish.sh           #   M3/ADR 0021 — mise run frontend:publish — verify + timoni build + flux push (the k8s path)
  scripts/frontend-serve.sh            #   pitchfork frontend daemon entrypoint (ADR 0009)
  scripts/lib/frontend.sh               #   frontend_repo_root + TOOLBOX_ATTESTATION_VERIFY seam + frontend_kube/tkn/strict_digest/host_image (T7b3)
  scripts/tests/*.bats + helper.bash

ci/                                  # reusable Tekton defs — Flux-reconciled from a GitRepository, OCI-bundle form eventual (ADR 0014/0015)
  tasks/{buildkit-build,git-clone,scan-attach,gate}.yaml   #   T7b1–T7b3 — clone → build → scan-attach → gate; no script:; disable-ipv6 sysctl step 0
  tasks/kustomization.yaml            #   T7c Inc.2 — per-path inventory (the 4 Task defs only)
  pipelines/build-scan-approve.yaml    #   T7b1/T7b2/T7b3 — clone-app → clone-defs → build → scan-attach → gate (shared + buildkitd-config workspaces, retries on clones)
  pipelines/kustomization.yaml        #   T7c Inc.2 — per-path inventory (the Pipeline def only)
  runtime/namespace.yaml               #   T7a ✓ — the `ci` namespace (no RBAC — the build SA needs none)
  runtime/buildkitd-mirror.yaml        #   T7b1-followup — buildkitd.toml ConfigMap: mirror docker.io + gcr.io → in-cluster zot (interim; OrbStack IPv6-egress defect)
  runtime/kustomization.yaml          #   T7c Inc.2 — per-path inventory (namespace + mirror CM only)
  scripts/registry-seed.sh             #   T7b1-followup — host crane-copy of a Dockerfile's base images into zot (mise run frontend:seed)
  scripts/kubeconform-scan.sh + chainsaw-test.sh + lib/ci.sh + tests/   # T7a ✓ (tekton-taskrun.sh deleted in T7b1)
  tests/crd-schemas/{task,pipeline,pipelinerun}_v1.json  #   Tekton v1 CRD schemas (vendored from the pinned release) for kubeconform
  tests/build-pipeline/chainsaw-test.yaml    #   [k8s]-gated: webhook accepts the 5 defs; no script:; posture + full DAG + G1 standalone gate TaskRun
  tests/build-pipeline/fixtures/scan-*.yaml  #   trivy-report ConfigMaps (critical/clean/malformed) for the G1 gate test

environments/local/                  # the ONE deployment target — owns its OpenBao unit + Flux config + orchestration
  main.tf                               #   applies module "secret_openbao_local" { source = "./openbao" }
  openbao/                              #   the local-OpenBao tofu unit (ADR 0012) — *.tf, templates/, tests/*.tftest.hcl
  flux/                                 #   T7c — FluxInstance + operator/cert-manager/kyverno HelmReleases + the Kustomization CRs (zot-sync, ci-*, cert-manager-pki, kyverno-policy, frontend*); *.lock; tests/crd-schemas/ (ADR 0015)
  kyverno/                              #   K1/ADR 0020 — the ImageValidatingPolicy + its approval-pubkey ConfigMap (configMapGenerator) + tests/crd-schemas/
  cert-manager/                         #   T7c Inc.4 — the dev-PKI CRs (ADR 0016)
  openbao/                              #   the local-OpenBao tofu unit (ADR 0016) — a raft StatefulSet, key-preserving snapshot restore
  zot/                                  #   T7b0 — committed manifests; reconciled by environments/local/flux/zot-sync.yaml (T7c, was `mise run local:zot:install`)
  tekton/                               #   T7c Inc.0 — release.lock (SHA-256) for tekton-install.sh; the *controller* install stays a checksum-gated `kubectl apply`, a named Flux prerequisite (ADR 0015)
  tests/{flux,kyverno,frontend}/**/chainsaw-test.yaml   #   [k8s]-gated running-state asserts (flux-/kyverno-/frontend-chainsaw.sh)
  scripts/openbao-{bootstrap,reset,snapshot}.sh + {flux,kyverno,frontend}-chainsaw.sh + {flux,cert-manager,kyverno}-kubeconform.sh + flux-bootstrap.sh + lib/ + tests/

modules/                             # reusable, versioned, URL-consumed OpenTofu modules only — README today
                                     # (the deferred production secret-openbao is the first candidate; Tekton
                                     #  defs are NOT here — they are OCI bundles in ci/, see ADR 0014)

.chainsaw.yaml                       # repo-root chainsaw Configuration — every wrapper passes --config; namespace.fastDelete: true so a loaded single-node cluster's slow ephemeral-ns teardown never fails `mise run check` (investigated 2026-09-10)
```

OpenBao/Transit is not per-consumer: `approval-key` and a future
`chains-provenance-key` are two entries in one `transit_keys` list in
`environments/local/main.tf` (input to the `./openbao` unit), not two
instances. The local OpenBao daemon is machine-global — registered in
`~/.config/pitchfork/config.toml` with `dir = $OPENBAO_STATE_DIR`
(`~/.local/state/toolbox/openbao/`), **not** in the repo `pitchfork.toml`
(ADR 0010). `attestation/` only ever names a key
(`openbao://approval-key`) — it never provisions OpenBao. See
`environments/local/README.md` for the bootstrap/reset/snapshot runbook.

**No embedded scripts in Tekton YAML** — every Task step is a single pinned
CLI invocation via Kubernetes' native `command`/`args`, never a `script:`
block (CLAUDE.md § Constraints). Anything a CLI can't express — the
strict-`sha256` guard, verification, the go/no-go approval
(`attestation-sign.sh`) — lives in a `shellcheck`-clean, `bats`-tested
script the repo owner runs, never in the Task graph, exactly as a
required-reviewer click is "manual" in any CI system. **The build digest is
never a Tekton result** (T7b re-cut, 2026-09-08): every Task addresses the
image by `$(IMAGE):$(APP_REVISION)` (the `cv_frontend` git SHA as the tag),
ordering is `runAfter`, and `oras resolve` produces the immutable digest
once at the operator boundary — the only value-consumer, `attestation-sign.sh`,
runs outside the pipeline. ADR 0001 holds: the tag is a convenience alias;
the signed chain still pins the digest.

## Phasing

Sequenced so each phase adds one new moving part and ships/tests
independently (Gall's Law). The full sequencing lives in `TODOS.md`.

- **Phase 1 — shipped (T1–T6).** `mise.toml` pinned; the distroless build
  runs as a GitHub Actions workflow to GHCR; `trivy` scan + CRITICAL gate +
  CycloneDX SBOM + scan-report referrers; OpenBao Transit (`approval-key`)
  provisioned by `environments/local/openbao/` (applied by
  `environments/local/main.tf`), supervised by `pitchfork`;
  `attestation-sign.sh` / `attestation-verify.sh` / `frontend-deploy.sh`
  proven live against real GHCR; the demo consumer is a local `pitchfork`
  container ([ADR 0009](../adr/0009-demo-consumer-is-local-container-not-k8s.md));
  `mise run local:openbao:snapshot` for backup, `mise run local:openbao:bootstrap` to restore.
  Registry is **GHCR** — hosted, zero-ops, unmetered on public repos.

- **Phase 2 — Tekton (T7a ✓ + `ci/` skeleton ✓ 2026-09-08; T7b re-cut
  2026-09-08).**
  Move the build/scan/attach/gate path into reusable Tekton Tasks + a Pipeline
  on `orb start k8s` ([ADR 0003](../adr/0003-tekton-pipelines-on-orbstack-k8s.md)),
  in the `ci/` concern ([ADR 0014](../adr/0014-tekton-defs-are-oci-bundles-in-ci.md);
  the defs' interim *distribution* is a plain Flux `Kustomization`,
  [ADR 0015](../adr/0015-flux-precedes-in-cluster-openbao-gitrepository-plain-yaml.md)).
  Builder
  is **daemonless rootless BuildKit**. **T7a** ✓ — feasibility spike + the `ci/`
  skeleton (`tasks/buildkit-build.yaml`, `runtime/namespace.yaml`, the
  kubeconform / chainsaw scripts, the interim `mise run local:tekton:install`,
  pinned Tekton v1.6.0). **T7b** (re-cut, plan `~/.claude/plans/t7b-pipeline-recut.md`)
  — **T7b0** interim `zot` on orb (pulled forward from T7d — removes the interim
  `gh` push token); **T7b1** `git-clone` Task + the `clone → build` Pipeline
  (delete `tekton-taskrun.sh`); **T7b1-followup** hermetic build — host zot
  seed + `buildkitd.toml` registry mirror + a one-shot `disable-ipv6` sysctl
  step, working around this OrbStack cluster's IPv6-egress defect (the only
  privileged container in the pipeline); **T7b2** `scan-attach` Task (trivy
  json + native cyclonedx, one DB pull, `oras attach` ×2 — its own
  `disable-ipv6` step for the DB pull); **T7b3** `gate` Task + the full Pipeline +
  `deploy/frontend/pipelinerun.cue` (plain CUE + `cue export -t`, NOT a Timoni
  module — a PipelineRun is fire-and-forget) rendered by `frontend-build.sh`
  (`mise run frontend:build`) + an end-to-end demo. The first real Timoni
  module is the `cv_frontend` **app deployment**, authored during/after T7c.
  **T7c** — pre-plan done ([ADR 0015](../adr/0015-flux-precedes-in-cluster-openbao-gitrepository-plain-yaml.md)):
  Increment 0 (checksum-gated Tekton install) → 1a/1b (Flux bootstrap +
  chainsaw) → 2 (Flux reconciles `zot` + `ci/{runtime,tasks,pipelines}` from a
  `GitRepository`) all shipped; Increment 4+ (in-cluster OpenBao) is a
  separate plan. **Distribution phase** — pin + cosign-sign the defs as OCI
  bundles, retire `build-cv-frontend.yml`. **T7d** — production repoint. Full
  detail in `TODOS.md`.

  **T7a Step 1 spike result (2026-09-08, orb k8s v1.35.6, Tekton Pipelines
  v1.6.0):** daemonless rootless BuildKit built `cv_frontend` in-cluster and
  pushed `linux/arm64` by digest to GHCR (`docker pull` of that digest
  verified, config `arch=arm64`). The four answers:
  1. **Rootless viability** — works, no privileged pod. Minimum pod posture:
     `runAsUser/Group: 1000`, `runAsNonRoot: true`,
     `seccompProfile: {type: Unconfined}`, `allowPrivilegeEscalation: true`
     (setuid-less `newuidmap` uses **file capabilities**, so `no_new_privs`
     must be OFF), `capabilities: {drop: [ALL], add: [SETUID, SETGID]}` (both
     must stay in the bounding set for `newuidmap`/`newgidmap`), and
     `BUILDKITD_FLAGS=--oci-worker-no-process-sandbox` (**required** — without
     it the dockerfile-frontend step fails to solve; k8s user-namespaces
     `hostUsers: false` is **not** an option because Tekton's `podTemplate`
     does not expose it).
  2. **In-cluster GHCR push** — the `gh auth token` interim credential works,
     wired as a `docker-registry` Secret and copied to
     `$DOCKER_CONFIG/config.json` inside the step.
  3. **Pod privilege posture** — **no** `privileged`, **no** `CAP_SYS_ADMIN`,
     **no** `CAP_SYS_PTRACE`. The residual surface is `SETUID`/`SETGID` +
     `allowPrivilegeEscalation` + `seccomp: Unconfined` + the
     no-process-sandbox flag (host-PID-namespace exposure inside the build
     pod). Blast radius: the single-user OrbStack VM.
  4. **Digest** — recorded; cross-builder parity vs the Phase-1 GHA build is
     not a gate (GHA retires in the post-T7c distribution phase); byte
     reproducibility is T8.

- **Phase 3 — Tekton Chains (T8).** Install Chains; a second OpenBao Transit
  key (`chains-provenance-key`) with an access policy denying it
  `approval-key`; automatic signed SLSA provenance per build. First task:
  widen OpenBao's listener past loopback with real TLS so an in-cluster pod
  can reach it.

- **Phase 4 — the CI check gate (shipped).**
  `.github/workflows/check.yml` runs the full `mise run check` matrix (the
  `hk` `check` hook) on every push and every PR to main — the heavy bats +
  `tofu test` layer the pre-push hook skips. One definition (`hk.pkl`),
  two entry points. Report-only: no branch protection (a solo repo makes
  `enforce_admins` a false choice), revisited if a second committer joins.
  **Per-commit `git bisect` safety** comes from the **squash-merge
  policy** (`CLAUDE.md` § CI check gate & merge policy), not a
  history-replay workflow: every push to main is one commit, and
  `check.yml` on that commit is the per-commit gate. Independent of
  Phases 1–3.

## Negative space (deliberately not used)

- **Kyverno admission-time enforcement on a *production* cluster** — couples
  the Tekton set, `cluster-k0sctl`, and Kyverno mechanics into one chain;
  the `ci`-namespace privilege-scoping policies stay deferred to that work
  (`TODOS.md`). Narrowed by [ADR 0020](../adr/0020-imagevalidatingpolicy-on-the-dev-reference-cluster.md):
  one `ImageValidatingPolicy` DOES run on the **dev reference cluster**,
  verifying the approval attestation at admission for the in-cluster
  `cv_frontend` — the declarative equal of `frontend-serve.sh`'s launch
  re-verify (Plan B K1).
- **Paketo buildpacks** — removed ([ADR 0007](../adr/0007-distroless-dockerfile-not-buildpacks.md)).
- **apko / melange** — fully declarative image build; an innovation-token
  overspend for one npm app.
- **Multi-arch builds** — `linux/arm64` only ([ADR 0008](../adr/0008-arm64-only.md));
  deferred to a real amd64 consumer.
- **`buildx --sbom` / `--provenance`** — emit SPDX in the image index, not a
  Referrers-API referrer.
- **`docker buildx --driver=kubernetes`** — manages a standing buildkitd
  pod; heavier than `buildctl-daemonless.sh` (rootless buildkitd inside the
  TaskRun pod) for no gain here. Rejected in the T7 planning
  ([ADR 0014](../adr/0014-tekton-defs-are-oci-bundles-in-ci.md), `TODOS.md`).
- **Standing buildkitd Deployment + KEDA scale-to-zero** — daemonless
  removes the standing service, so there is nothing to scale; the build
  cache goes to the registry, not a PVC. Revisit only on measured
  warm-build latency pain.
- **Path-encoded Tekton catalog versions** (`task/<name>/<version>/`) —
  contradicts digest-as-the-pin ([ADR 0001](../adr/0001-digest-is-the-trust-boundary.md));
  Tekton bundles are OCI artifacts pinned by digest
  ([ADR 0014](../adr/0014-tekton-defs-are-oci-bundles-in-ci.md)).
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
│ checkout cv_frontend@pinned-SHA    │           │ machine-global pitchfork  │
│            │                       │           │  daemon: openbao (raft)   │
│            ▼                       │           │   Transit: approval-key   │
│ docker buildx build                │           │     └─ never leaves       │
│   --platform linux/arm64 --push    │           │        OpenBao            │
│   (deploy/frontend/Dockerfile)     │           └───────────────────────────┘
│            │  digest ◀ meta.json   │                        ▲
│            ▼                       │                        │ cosign attest
│ trivy scan --format json          │                        │ --key openbao://
│   └─ oras attach scan.json         │                        │   approval-key
│            ▼                       │        ┌───────────────┴───────────────┐
│ trivy --format cyclonedx          │        │ mise run attestation:sign     │
│   └─ oras attach sbom.cdx.json     │        │   -- <ref>                    │
│            ▼                       │        │  show SBOM + scan report      │
│ trivy image --severity CRITICAL   │        │  human: approve / reject      │
│   --exit-code 1   (blocking, LAST) │◀───────┤  ALWAYS signs; prints att-dig │
└─────────────┬──────────────────────┘        └───────────────────────────────┘
              │ image + SBOM + scan.json + approval referrers
              ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │ mise run frontend:deploy -- <ref> <attestation-digest>           │
   │   attestation-verify.sh  (via $TOOLBOX_ATTESTATION_VERIFY seam):  │
   │     cosign verify-blob-attestation --bundle <blob>                │
   │       --key attestation/cosign-approval.pub  (committed; no bao)  │
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
| `mise run attestation:sign` | OpenBao unreachable / uninitialised / sealed / unauthorized / missing-key | `openbao-preflight.sh` distinguishes all five, exit 3, names the fix |
| `mise run attestation:sign` | Ctrl-C / EOF / empty at the prompt | no signed record written, clean abort |
| `mise run attestation:sign` | `cosign attest` signs but the registry push fails | read-back check fails loudly, non-zero; no false "approved" |
| `mise run frontend:deploy` / launch re-verify | attestation missing / bad sig / wrong subject / verdict rejected | `attestation-verify.sh` exit 1 — "attestation verification failed" (cosign's claim check) or "verdict: rejected" (CUE); cosign's own output in the log |
| launch re-verify | GHCR transient failure | `attestation-verify.sh` exit 3 → `frontend-serve.sh` bounded retry + backoff → visible stopped state, never a hang |
| `attestation-verify.sh` | OpenBao down | not applicable — verify never touches OpenBao |
| OpenBao Transit | raft store lost | past approvals still verify (pubkey in-repo); re-run `mise run local:openbao:bootstrap` (key-preserving -force restore) restores signing ability |

---

Decisions and rationale: [`docs/adr/`](../adr/README.md). Open work:
[`TODOS.md`](../../TODOS.md). Revise this document in place, present tense —
do not strike-through; record a superseding ADR instead.
