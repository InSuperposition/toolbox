# ci

## Abstract

The consumer-agnostic **reusable Tekton build definitions** for the
digest-as-source-of-truth pipeline
(`docs/designs/digest-as-source-of-truth.md`,
[ADR 0014](../docs/adr/0014-tekton-defs-are-oci-bundles-in-ci.md)). Phase 2
of the CI pipeline (`TODOS.md` T7) moves the build off GitHub Actions and
into `orb start k8s`: a daemonless, rootless BuildKit Task builds an app
from its Dockerfile and pushes it, with no privileged pod;
`ci-taskrun.sh` then resolves the pushed **manifest digest** and pins on
it (the digest is the trust boundary — ADR 0001).

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
| `tasks/buildkit-build.yaml` | T7a — `buildctl-daemonless.sh` rootless build → push under a caller-supplied `TAG`. One step, pinned `command` + `args`, **no `script:`** (CLAUDE.md § Constraints). Params only (`IMAGE`, `TAG`, `PLATFORM`, `DOCKERFILE`, `CONTEXT_SUBPATH`, `BUILDKITD_FLAGS`); never names `cv_frontend`. No Tekton result — the caller resolves the digest (see below). No build cache (T7b adds it). |
| `runtime/namespace.yaml` | the `ci` Namespace — nothing else. No `Role`/`RoleBinding`: the build step reads a **mounted** Secret, not the k8s API, so its ServiceAccount needs no verbs (the TaskRun also sets `automountServiceAccountToken: false`). |
| `scripts/ci-taskrun.sh` | `mise run ci:taskrun` — stage the app context + the Dockerfile dir into one per-run hostPath workspace (two `subPath` bindings), apply the Task, create a TaskRun with a captured name, stream logs. Then `oras resolve $IMAGE:$TAG` → the manifest digest, `ci_is_strict_digest` validates it, and it pins on the digest to verify the Step-1 criteria (`oras` config `arch=arm64`, `docker pull`, pod `securityContext`). `--keep` / `--teardown` (also best-effort deletes the tag). |
| `scripts/lib/ci.sh` | shared shell: repo-root resolution, the strict `^sha256:[0-9a-f]{64}$` digest guard (`ci_is_strict_digest`), the `--context orbstack` kube-context guard. |
| `scripts/tests/*.bats`, `scripts/tests/helper.bash` | the matrix. `k8s_available()` **skips** (not `exit 1`) without orb / a kubeconfig — T7a's in-cluster build is a local spike, not a pre-merge gate (GitHub runners have no OrbStack). |
| `tests/buildkit-build/chainsaw-test.yaml` | `[k8s]`-gated — apply the Task, assert the Tekton webhook accepts it, that it has exactly one step with **no `script:` field**, and that the spike-proven `securityContext` posture (the ceiling) has not drifted. The full build→push assertions are `mise run ci:taskrun` + the recorded spike (T7b adds a credential-light chainsaw build). |

## Why the digest is resolved in `ci-taskrun.sh`, not a Tekton result

The Task pushes under a per-run tag and emits **no** `IMAGE_DIGEST` result;
`ci-taskrun.sh` does `oras resolve $IMAGE:$TAG` and pins on the digest. A
Tekton step-result would need embedded shell (`jq … > $(results…path)`) —
which CLAUDE.md forbids — and the shell-free alternatives don't fit T7a:
step-stdout→result is `enable-api-fields: alpha` (the controller runs
`beta`), `buildctl` has no bare-digest output flag, and
`coschedule: workspaces` forbids a second PVC-backed "meta" workspace. T7b
re-adds a proper `IMAGE_DIGEST` result via a committed extract script when
it builds the Pipeline (`TODOS.md` T7b).

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
