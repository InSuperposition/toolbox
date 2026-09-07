# ci

## Abstract

The consumer-agnostic **reusable Tekton build definitions** for the
digest-as-source-of-truth pipeline
(`docs/designs/digest-as-source-of-truth.md`,
[ADR 0014](../docs/adr/0014-tekton-defs-are-oci-bundles-in-ci.md)). Phase 2
of the CI pipeline (`TODOS.md` T7) moves the build off GitHub Actions and
into `orb start k8s`: a daemonless, rootless BuildKit Task builds an app
from its Dockerfile and pushes the image **by digest**, with no privileged
pod.

This concern **owns** the Task/Pipeline YAML, the `ci` namespace, and the
scripts that stage inputs and drive a run. It **may depend on** `tests/lib`
only. Like `attestation/`, it **never names a consumer** — the forbidden
edge `ci ─╳▶ deploy/*` is machine-checked
(`rules/boundary-ci.yml`, `docs/designs/repo-structure.md` § Enforcement).
The per-consumer instantiation — a `PipelineRun` binding one consumer's
params and the pinned bundle digests — lives in `deploy/<consumer>/` (T7b).

The Tekton **controller** install and `zot` are vendored upstreams, not our
reusable code — they are `environments/local/`'s concern (an interim
`local:tekton:install` mise task now, a Flux `OCIRepository` /
`Kustomization` in T7c), never `ci/`.

## `ci/` vs `.github/workflows/`

| | holds | pinned by |
|---|---|---|
| `ci/` | **what** the build does — the Tekton Task/Pipeline graph, parameterised, consumer-agnostic | OCI bundle digest (T7b: `tkn bundle push` → `@sha256:` in the resolver ref) |
| `.github/workflows/` | **where/when** it runs — the GitHub-hosted runner, the trigger | the workflow file on the branch |

Phase 1's `.github/workflows/build-cv-frontend.yml` is retired at the end of
T7b, once build + evidence + approval + consumption are demonstrated
in-cluster end to end.

## Files

| File | Role |
|---|---|
| `tasks/buildkit-build.yaml` | T7a — `buildctl-daemonless.sh` rootless build → push by digest. Params only (`IMAGE`, `PLATFORM`, `DOCKERFILE`, `CONTEXT_SUBPATH`, `BUILD_ARGS`); never names `cv_frontend`. Result: `IMAGE_DIGEST` (strict `sha256:`). No build cache (T7b adds it). |
| `runtime/namespace.yaml` | the `ci` Namespace — nothing else. No `Role`/`RoleBinding`: the build step reads a **mounted** Secret, not the k8s API, so its ServiceAccount needs no verbs (the TaskRun also sets `automountServiceAccountToken: false`). |
| `scripts/ci-taskrun.sh` | `mise run ci:taskrun` — stage the app context + the Dockerfile dir into one per-run hostPath workspace (two `subPath` bindings), apply the Task, create a TaskRun with a captured name, stream logs, verify per the Step-1 criteria (strict `sha256`, `oras` config `arch=arm64`, `docker pull`, pod `securityContext`). `--keep` / `--teardown`. |
| `scripts/lib/ci.sh` | shared shell: repo-root resolution, the strict `^sha256:[0-9a-f]{64}$` digest guard, the `--context orbstack` kube-context guard. |
| `scripts/tests/*.bats`, `scripts/tests/helper.bash` | the matrix. `k8s_available()` **skips** (not `exit 1`) without orb / a kubeconfig — T7a's in-cluster build is a local spike, not a pre-merge gate (GitHub runners have no OrbStack). |
| `tests/buildkit-build.chainsaw.yaml` | `[k8s]`-gated — apply Task + TaskRun, assert `Succeeded` + strict `sha256` result + `arm64` config + no privileged pod + no mounted SA token + the default SA cannot `create taskruns` / `get secrets`. |

## Why a `script:` step body, not `command`/`args`

`docs/designs/digest-as-source-of-truth.md` states the ideal: every Task
step is a single pinned CLI invocation. `buildkit-build.yaml` keeps one
short `script:` block because `buildctl`'s digest lands in a
`--metadata-file` that needs a `jq` extraction + a strict-format guard
before it can be written to `$(results.IMAGE_DIGEST.path)`, and shell
redirection is not expressible in `command`/`args`. This is a **step body**
— the analogue of a container entrypoint — not embedded orchestration
config: it is a fixed, reviewed sequence with no branching, and every real
decision (staging, verification, teardown) lives in `ci-taskrun.sh`, which
is `shellcheck`-clean and `bats`-tested. Same carve-out shape as
`deploy/frontend/Dockerfile` (`CLAUDE.md` § Constraints).

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
