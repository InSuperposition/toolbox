# ci

## Abstract

The consumer-agnostic **reusable Tekton build definitions** for the
digest-as-source-of-truth pipeline
(`docs/designs/digest-as-source-of-truth.md`,
[ADR 0014](../docs/adr/0014-tekton-defs-are-oci-bundles-in-ci.md)). Phase 2
of the CI pipeline (`TODOS.md` T7) moves the build off GitHub Actions and
into `orb start k8s`: a `git-clone` Task fetches the app + the toolbox
Dockerfile at pinned SHAs, a daemonless rootless BuildKit Task builds and
pushes a **SHA-tagged** image to the local zot. The build step is
unprivileged; a separate one-shot `disable-ipv6` `sysctl` step is the only
privileged container (§ Deterministic builds on OrbStack).

This concern **owns** the Task/Pipeline YAML, the `ci` namespace, and the
scripts that drive a chainsaw run. It **may depend on** `tests/lib` only.
Like `attestation/`, it **never names a consumer** — the forbidden edge
`ci ─╳▶ deploy/*` is machine-checked (`rules/boundary-ci.yml`,
`docs/designs/repo-structure.md` § Enforcement). The per-consumer
instantiation — a `PipelineRun` binding one consumer's repo URLs, SHAs and
image ref — lives in `deploy/<consumer>/` (a Timoni module, T7b3).

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
| `pipelines/build-scan-approve.yaml` | T7b1 — the `clone-app → clone-defs → build` DAG over the `shared` workspace + a `buildkitd-config` ConfigMap workspace. `retries: 2` on the clone tasks (OrbStack DNS-timeout mode). T7b2 adds `scan-attach` (`runAfter build`); T7b3 adds `gate` (last). Consumer values are PipelineRun params. |
| `runtime/namespace.yaml` | the `ci` Namespace — nothing else. No `Role`/`RoleBinding`: the steps touch a mounted workspace + a registry, never the k8s API (`automountServiceAccountToken: false` on the pods). |
| `runtime/buildkitd-mirror.yaml` | the `buildkitd-mirror` ConfigMap — a `buildkitd.toml` mirroring `docker.io` + `gcr.io` to the in-cluster zot. Bound to the build Task's `buildkitd-config` workspace by the PipelineRun. INTERIM + local-specific (§ Deterministic builds on OrbStack). |
| `scripts/registry-seed.sh` | host-side: `crane copy` every `# syntax=` / `FROM …@sha256:` ref in a Dockerfile into the local zot, digests preserved, so the mirror has the base images. `mise run frontend:seed`. Consumer-agnostic — the Dockerfile is an argument. |
| `scripts/chainsaw-test.sh` / `kubeconform-scan.sh` / `lib/ci.sh` | the hk `chainsaw` (`[k8s]`-gated) + `kubeconform` gates and their shared shell (repo-root, the strict `^sha256:[0-9a-f]{64}$` guard `ci_is_strict_digest`, the `--context orbstack` guard). |
| `scripts/tests/*.bats`, `scripts/tests/helper.bash` | pure-shell cases for the gate scripts' skip / fail decisions. No `[k8s]` bats case (the fake-bin shim would fake the gate true, then exec the real binary — a runner failure). |
| `tests/build-pipeline/chainsaw-test.yaml` | `[k8s]`-gated — the Tekton webhook accepts all three defs, none carries a `script:` field, the spike-proven build `securityContext` (the ceiling) has not drifted, the only privileged container is the `disable-ipv6` `sysctl` step, and the Pipeline DAG is `clone-app → clone-defs → build` over the `shared` + `buildkitd-config` workspaces. The full `clone → build → push → oras resolve → docker pull` run is an operator `tkn pipeline start` (recorded in `TODOS.md` T7b1), the way T7a's spike proved buildkit. |
| `tests/crd-schemas/{task,pipeline}_v1.json` | Tekton v1 CRD schemas vendored from the pinned release for `kubeconform` (regenerate on a Tekton bump — `environments/local/README.md` § Tekton). |

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
   net.ipv6.conf.*.disable_ipv6=1` runs first in `git-clone` and
   `buildkit-build`. Steps share the pod netns, so every later dialer uses
   v4. DNS / AAAA resolution is untouched. This is the **only** privileged
   container in the pipeline (`ci` ns is PSA `privileged`).
3. **`retries: 2`** on the clone tasks — the lever for the `git` DNS-timeout
   mode (the build has no external egress left to retry).

Rejected: disabling AAAA cluster-wide (changes resolution semantics; kept
only as a documented `dnsConfig` rollback), rewriting the app Dockerfile's
`FROM` lines (couples the app to infra), zot `onDemand` pull-through (its
regclient inherits the same bug).
