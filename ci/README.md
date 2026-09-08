# ci

## Abstract

The consumer-agnostic **reusable Tekton build definitions** for the
digest-as-source-of-truth pipeline
(`docs/designs/digest-as-source-of-truth.md`,
[ADR 0014](../docs/adr/0014-tekton-defs-are-oci-bundles-in-ci.md)). Phase 2
of the CI pipeline (`TODOS.md` T7) moves the build off GitHub Actions and
into `orb start k8s`: a `git-clone` Task fetches the app + the toolbox
Dockerfile at pinned SHAs, a daemonless rootless BuildKit Task builds and
pushes a **SHA-tagged** image to the local zot, with no privileged pod.

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
| `tasks/git-clone.yaml` | T7b1 — blobless shallow clone of a public repo at a pinned `REVISION` into `<output>/<SUBDIR>`. Two steps (`git clone --no-checkout`, `git checkout --detach`), pinned `command` + `args`, **no `script:`**. Reuses the pinned `moby/buildkit:rootless` image (it ships `git`) — one image digest for the whole pipeline. Steps run as root; see § Workspaces. |
| `tasks/buildkit-build.yaml` | T7a posture, T7b1-rewired — `buildctl-daemonless.sh` rootless build. Context = the `source` workspace; Dockerfile = `$(DOCKERFILE_DIR)` in `build-defs`. Pushes `$(IMAGE):$(APP_REVISION)` (the app git SHA as the tag), `registry.insecure=$(REGISTRY_INSECURE)` (default `true`, for the loopback zot). One step, pinned `command` + `args`, **no `script:`**, **no Tekton result** (see below), no `dockerconfig` workspace (zot is credential-free). Params only; never names `cv_frontend`. |
| `pipelines/build-scan-approve.yaml` | T7b1 — the `clone-app → clone-defs → build` DAG over one `shared` workspace. T7b2 adds `scan-attach` (`runAfter build`); T7b3 adds `gate` (last). Consumer values are PipelineRun params. |
| `runtime/namespace.yaml` | the `ci` Namespace — nothing else. No `Role`/`RoleBinding`: the steps touch a mounted workspace + a registry, never the k8s API (`automountServiceAccountToken: false` on the pods). |
| `scripts/chainsaw-test.sh` / `kubeconform-scan.sh` / `lib/ci.sh` | the hk `chainsaw` (`[k8s]`-gated) + `kubeconform` gates and their shared shell (repo-root, the strict `^sha256:[0-9a-f]{64}$` guard `ci_is_strict_digest`, the `--context orbstack` guard). |
| `scripts/tests/*.bats`, `scripts/tests/helper.bash` | pure-shell cases for the gate scripts' skip / fail decisions. No `[k8s]` bats case (the fake-bin shim would fake the gate true, then exec the real binary — a runner failure). |
| `tests/build-pipeline/chainsaw-test.yaml` | `[k8s]`-gated — the Tekton webhook accepts all three defs, none carries a `script:` field, the spike-proven build `securityContext` (the ceiling) has not drifted, and the Pipeline DAG is `clone-app → clone-defs → build` over one workspace. The full `clone → build → push → oras resolve → docker pull` run is an operator `tkn pipeline start` (recorded in `TODOS.md` T7b1), the way T7a's spike proved buildkit. |
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

One workspace, `shared`, backed by a per-run `volumeClaimTemplate` in the
PipelineRun. Tekton `coschedule: workspaces` forbids a single TaskRun
binding two **distinct** PVCs — so `clone-app` writes `shared/app`,
`clone-defs` writes `shared/defs`, and the `build` Task binds that one claim
twice via `subPath` (`source` → `app`, `build-defs` → `defs`). This is why
T7a's hostPath-PV / `common_prefix` dance was needed then and is gone now.

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

**Not** needed: `privileged`, `CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, k8s
user-namespaces. Blast radius is the single-user OrbStack VM. A Kyverno
exception scoped to the `ci` namespace is a T8 / Kyverno-module concern.
