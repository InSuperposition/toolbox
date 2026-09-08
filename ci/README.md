# ci

## Abstract

The consumer-agnostic **reusable Tekton build definitions** for the
digest-as-source-of-truth pipeline
(`docs/designs/digest-as-source-of-truth.md`,
[ADR 0014](../docs/adr/0014-tekton-defs-are-oci-bundles-in-ci.md)). Phase 2
of the CI pipeline (`TODOS.md` T7) moves the build off GitHub Actions and
into `orb start k8s`: a `git-clone` Task fetches the app + the toolbox
Dockerfile at pinned SHAs, a daemonless rootless BuildKit Task builds and
pushes a **SHA-tagged** image to the local zot, a `scan-attach` Task runs
`trivy` and hangs the JSON report + a CycloneDX SBOM off the image digest
as OCI 1.1 referrers, and a `gate` Task fails the run on a CRITICAL
finding (reading the same `scan.json` scan-attach attached, so the verdict
can't drift from the evidence). The work steps are unprivileged; each
Task's one-shot `disable-ipv6` `sysctl` step is the only privileged
container (§ Deterministic builds on OrbStack) — `gate` has none, it reads
a local file.

This concern **owns** the Task/Pipeline YAML, the `ci` namespace, and the
scripts that drive a chainsaw run. It **may depend on** `tests/lib` only.
Like `attestation/`, it **never names a consumer** — the forbidden edge
`ci ─╳▶ deploy/*` is machine-checked (`rules/boundary-ci.yml`,
`docs/designs/repo-structure.md` § Enforcement). The per-consumer
instantiation — a `PipelineRun` binding one consumer's repo URLs, SHAs and
image ref — lives in `deploy/<consumer>/`, rendered from **plain CUE**
(`deploy/frontend/pipelinerun.cue` + `cue export -t`, T7b3 — not a Timoni
module: a PipelineRun is fire-and-forget, so Timoni's module + bundle +
vendored `cue.mod` footprint doesn't pay off).

The Tekton **controller** install and **zot** are vendored upstreams, not
our reusable code — they are `environments/local/`'s concern (interim
`local:tekton:install` / `local:zot:install` mise tasks now, Flux
`OCIRepository` / `Kustomization` in T7c/T7d), never `ci/`.

## `ci/` vs `.github/workflows/`

| | holds | pinned by |
|---|---|---|
| `ci/` | **what** the build does — the Tekton Task/Pipeline graph, parameterised, consumer-agnostic | content digest (the distribution mechanism — `tkn bundle` vs Flux `OCIRepository` — is decided in the T7c pre-plan; `TODOS.md` T7) |
| `.github/workflows/` | **where/when** it runs — the GitHub-hosted runner, the trigger | the workflow file on the branch |

Phase 1's `.github/workflows/build-cv-frontend.yml` is retired in the
post-T7c distribution phase, once the pinned in-cluster path is stable
(`TODOS.md` T7).

## Files

| File | Role |
|---|---|
| `tasks/git-clone.yaml` | T7b1 — blobless shallow clone of a public repo at a pinned `REVISION` into `<output>/<SUBDIR>`. Three steps (`disable-ipv6` `sysctl`, `git clone --no-checkout`, `git checkout --detach`), pinned `command` + `args`, **no `script:`**. Reuses the pinned `moby/buildkit:rootless` image (it ships `git`) — one image digest for the whole pipeline. Steps run as root; see § Workspaces. |
| `tasks/buildkit-build.yaml` | T7a posture, T7b1-rewired — `buildctl-daemonless.sh` rootless build. Context = the `source` workspace; Dockerfile = `$(DOCKERFILE_DIR)` in `build-defs`; `--config /cfg/buildkitd.toml` from the `buildkitd-config` workspace (the registry mirror). Pushes `$(IMAGE):$(APP_REVISION)` (the app git SHA as the tag), `registry.insecure=$(REGISTRY_INSECURE)` (default `true`, for the loopback zot). Two steps (`disable-ipv6`, `build`), pinned `command` + `args`, **no `script:`**, **no Tekton result** (see below), no `dockerconfig` workspace (zot is credential-free). Params only; never names `cv_frontend`. |
| `tasks/scan-attach.yaml` | T7b2 — `trivy image` × 2 (JSON report → `shared/scan.json`, native CycloneDX SBOM → `shared/sbom.cdx.json`, one shared `--cache-dir` so the vuln DB is pulled once) then `oras attach` × 2 (referrer types `application/vnd.trivy.report+json`, `application/vnd.cyclonedx+json`). Five steps (`disable-ipv6` + 4), pinned `command` + `args`, **no `script:`**, **never blocks** (the CRITICAL gate is a separate Task, T7b3). `TRIVY_INSECURE` / `oras --plain-http=` carry `$(REGISTRY_INSECURE)`. Params only. |
| `tasks/gate.yaml` | T7b3 — the blocking CRITICAL gate. One step: `trivy convert --scanners=vuln --exit-code=2 --severity=CRITICAL --format=table scan.json` over the `shared` workspace. `--exit-code=2` (not 1) so a CRITICAL match and a trivy error are distinguishable — `frontend-build.sh` shows the loud override box only on exactly 2. No `disable-ipv6` step (reads a local file, no network → nothing privileged). Params-free, never names a consumer. |
| `pipelines/build-scan-approve.yaml` | T7b1/T7b2/T7b3 — the `clone-app → clone-defs → build → scan-attach → gate` DAG over the `shared` workspace + a `buildkitd-config` ConfigMap workspace. `retries: 2` on the clone tasks (OrbStack DNS-timeout mode). Consumer values are PipelineRun params. |
| `runtime/namespace.yaml` | the `ci` Namespace — nothing else. No `Role`/`RoleBinding`: the steps touch a mounted workspace + a registry, never the k8s API (`automountServiceAccountToken: false` on the pods). |
| `runtime/buildkitd-mirror.yaml` | the `buildkitd-mirror` ConfigMap — a `buildkitd.toml` mirroring `docker.io` + `gcr.io` to the in-cluster zot. Bound to the build Task's `buildkitd-config` workspace by the PipelineRun. INTERIM + local-specific (§ Deterministic builds on OrbStack). |
| `scripts/registry-seed.sh` | host-side: `crane copy` every `# syntax=` / `FROM …@sha256:` ref in a Dockerfile into the local zot, digests preserved, so the mirror has the base images. `mise run frontend:seed`. Consumer-agnostic — the Dockerfile is an argument. |
| `scripts/chainsaw-test.sh` / `kubeconform-scan.sh` / `lib/ci.sh` | the hk `chainsaw` (`[k8s]`-gated) + `kubeconform` gates and their shared shell (repo-root, the strict `^sha256:[0-9a-f]{64}$` guard `ci_is_strict_digest`, the `--context orbstack` guard). |
| `scripts/tests/*.bats`, `scripts/tests/helper.bash` | pure-shell cases for the gate scripts' skip / fail decisions. No `[k8s]` bats case (the fake-bin shim would fake the gate true, then exec the real binary — a runner failure). |
| `tests/build-pipeline/chainsaw-test.yaml` | `[k8s]`-gated — the Tekton webhook accepts all five defs, none carries a `script:` field, the spike-proven build `securityContext` (the ceiling) has not drifted, the only privileged container in each Task is its `disable-ipv6` `sysctl` step (`gate` has none), and the Pipeline DAG is `clone-app → clone-defs → build → scan-attach → gate` over the `shared` + `buildkitd-config` workspaces. **G1** — a standalone `gate` TaskRun against `fixtures/scan-{critical,clean,malformed}.yaml` (ConfigMap workspaces) asserts the step's terminated exitCode: `2` on a CRITICAL (run fails), `0` on a LOW-only report (run passes), `1` on a malformed report (run fails, but an error not a verdict). The full `clone → build → push → scan → attach → gate → oras resolve` run is an operator `mise run frontend:build` (recorded in `TODOS.md` T7b1/T7b2/T7b3). |
| `tests/build-pipeline/fixtures/scan-{critical,clean,malformed}.yaml` | minimal trivy-JSON-report ConfigMaps for the G1 gate test. |
| `tests/crd-schemas/{task,pipeline,pipelinerun}_v1.json` | Tekton v1 CRD schemas vendored from the pinned release for `kubeconform` (regenerate on a Tekton bump — `environments/local/README.md` § Tekton). `pipelinerun_v1.json` lets the `frontend-build.bats` render validate the rendered PipelineRun. |

## Why there is no Tekton `IMAGE_DIGEST` result

Inside the pipeline every task addresses the image by
`$(IMAGE):$(APP_REVISION)` — the app's git SHA as a deterministic tag.
Ordering is `runAfter`. The one consumer of the digest-as-a-value,
`attestation-sign.sh`, runs **outside** the pipeline — and `oras resolve`
(already pinned) turns the tag into the immutable digest there, in one
call, at the operator boundary. A Tekton result would need embedded shell
or `enable-api-fields: alpha` and buys nothing the tag doesn't. ADR 0001
holds: the tag is a convenience alias; the signed chain
(`attestation-sign.sh` → `frontend-deploy.sh`) still pins the digest, which
never leaves the human boundary. (`~/.claude/plans/t7b-pipeline-recut.md`,
`TODOS.md` T7b.)

## Workspaces

`shared` is backed by a per-run `volumeClaimTemplate` in the PipelineRun.
Tekton `coschedule: workspaces` forbids a single TaskRun binding two
**distinct** PVCs — so `clone-app` writes `shared/app`, `clone-defs` writes
`shared/defs`, and the `build` Task binds that one claim twice via `subPath`
(`source` → `app`, `build-defs` → `defs`). This is why T7a's hostPath-PV /
`common_prefix` dance was needed then and is gone now.

`buildkitd-config` is a **ConfigMap** workspace (not a PVC — no coschedule
constraint), bound to `runtime/buildkitd-mirror.yaml`. The build Task mounts
it at `/cfg` and passes `--config /cfg/buildkitd.toml` to `buildctl`.

The `git-clone` steps run as **root** (`runAsUser: 0`). The OrbStack
`local-path` PVC is not reliably group-writable under `fsGroup` (verified
2026-09-08 — `git clone` as uid 1000 fails "Permission denied" on `.git`).
Root writes the tree world-readable; the `build` step reads it back at its
careful rootless uid 1000. The posture that matters is on the build, not on
a clone of a public repo. The PipelineRun sets no `fsGroup`.

## Residual privilege surface

Rootless BuildKit on orb needs, and the chainsaw test asserts the **ceiling
of**, this posture (spike result, `TODOS.md` T7a):

- `capabilities: { drop: [ALL], add: [SETUID, SETGID] }` — `newuidmap` /
  `newgidmap` need both in the bounding set.
- `allowPrivilegeEscalation: true` — this image's `newuidmap` is file-cap
  based, not setuid; `no_new_privs` (which `false` forces) would break it.
- `seccompProfile: { type: Unconfined }` — rootlesskit needs `unshare` /
  `clone` that the `baseline` PSA seccomp profile blocks.
- `BUILDKITD_FLAGS: --oci-worker-no-process-sandbox` — required; without it
  the dockerfile-frontend step fails to solve.

**Not** needed by the `build` step: `privileged`, `CAP_SYS_ADMIN`,
`CAP_SYS_PTRACE`, k8s user-namespaces. Blast radius is the single-user
OrbStack VM. A Kyverno exception scoped to the `ci` namespace — and to the
named `disable-ipv6` sysctl below — is a Kyverno-module concern
(`TODOS.md` § Kyverno module).

## Deterministic builds on OrbStack

This OrbStack cluster gives pods a working AF_INET6 stack + `kube-dns` AAAA
records but **no routable IPv6 egress** (no v6 default route). Go registry
clients (buildkit, containerd, zot's regclient) and `git`'s resolver can
pick an unreachable AAAA and hard-fail — `connect: network is unreachable`,
~50% of external image fetches; plus a separate ~10% `git` DNS-proxy
timeout. Root cause: `/investigate` 2026-09-08 (`TODOS.md` T7b1-followup).

Three independent guards, all interim, all removed once the Cilium module
settles on a v4-only datapath (`TODOS.md` § Cilium):

1. **Host seed + registry mirror** — `mise run frontend:seed`
   (`scripts/registry-seed.sh`) copies the Dockerfile's digest-pinned base
   images into zot **from the host**, where IPv4 works. `runtime/buildkitd-mirror.yaml`
   then points `docker.io` + `gcr.io` at `zot.zot.svc.cluster.local:5000`,
   so the build's only egress is the in-cluster zot.
2. **`disable-ipv6` step** — a one-shot privileged `sysctl -w
   net.ipv6.conf.*.disable_ipv6=1` runs first in `git-clone`,
   `buildkit-build`, **and `scan-attach`** (trivy's vuln-DB pull is an
   external fetch the mirror does not cover). Steps share the pod netns, so
   every later dialer in the pod uses v4. DNS / AAAA resolution is
   untouched. It is the only privileged container in each Task (`ci` ns is
   PSA `privileged`). **This is now three Tasks — the pattern does not
   scale;** `TODOS.md` § Cilium tracks a 4th `disable-ipv6` step (or k0s
   replacing OrbStack) as the trigger to make the Cilium datapath call,
   which retires all of them at once.
3. **`retries: 2`** on the clone tasks — the lever for the `git` DNS-timeout
   mode (the build has no external egress left to retry).

Rejected: disabling AAAA cluster-wide (changes resolution semantics; kept
only as a documented `dnsConfig` rollback), rewriting the app Dockerfile's
`FROM` lines (couples the app to infra), zot `onDemand` pull-through (its
regclient inherits the same bug). Seeding trivy's vuln-DB repo into zot +
mirroring `ghcr.io` was weighed for `scan-attach` and deferred — "keep it
simple for now" (2026-09-08); it becomes the right move if the seed +
mirror survives the Cilium decision.
