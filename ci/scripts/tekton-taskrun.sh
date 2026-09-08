#!/usr/bin/env bash
set -euo pipefail

# `mise run ci:taskrun -- <context-dir> <dockerfile> <image-ref> [--keep|--teardown]`
#
# T7a Step 2 — drive one buildkit-build TaskRun on `orb start k8s`: stage
# the build context and the Dockerfile into per-run workspaces, apply the
# shared Task, create a TaskRun, stream its logs. The Task pushes under a
# per-run tag; this script then resolves the manifest digest from that tag
# (`oras resolve`), validates it (`ci_is_strict_digest`), pins on the
# digest, and verifies the Step-1 spike criteria (arm64 config, image
# pullable, no privileged pod) — the digest guard the Task no longer
# carries lives HERE. This is the disposable-spike ergonomics of T7a; T7b
# replaces the staging with a digest-pinned git-clone Task, wraps this in a
# Pipeline, and re-adds a proper Tekton IMAGE_DIGEST result (TODOS.md T7).
#
# Consumer-agnostic (ADR 0014, rules/boundary-ci.yml): every concrete path
# is an argument. <dockerfile> is a path to the Dockerfile FILE (its
# directory becomes the build-defs workspace, its basename the DOCKERFILE
# param); <context-dir> is the build context root. The per-consumer
# instantiation that knows `deploy/frontend/Dockerfile` lives in
# deploy/frontend/ (T7b), never here.
#
# Staging uses ONE per-run hostPath PV/PVC over the deepest directory that
# contains both the context and the Dockerfile (OrbStack mounts the macOS
# FS into the k8s node); the two workspaces bind that one claim with
# different subPaths — Tekton forbids two distinct PVCs in a TaskRun. The
# PV's claimRef is pinned to its PVC so concurrent runs never share a
# volume. T7b's digest-pinned git-clone Task removes the shared-parent
# constraint.
#
# Credentials: a per-run Secret (single `config.json` key) built from
# `gh auth token` at call time (mise-env-exec-chain — never an [env] var,
# never echo'd). Deleted on teardown. An expired token surfaces as a 401 on
# push; the fix is `gh auth login` / `gh auth refresh` with write:packages.
#
# Cleanup: on success this run's TaskRun + Secret + PVC/PV are deleted (and
# the push tag best-effort); on failure they are kept for inspection.
# --keep never deletes; --teardown always deletes. The `ci` namespace and
# the shared Task are never deleted.
#
# Exit 0  — TaskRun Succeeded and every verification passed.
# Exit 1  — a preflight check failed, the build failed, or verification failed.
# Exit 2  — bad arguments.
#
# Test seams: TOOLBOX_CI_KUBE_CONTEXT, TOOLBOX_CI_NAMESPACE (lib/ci.sh),
# TOOLBOX_CI_TASK_FILE, TOOLBOX_CI_TEKTON_NS, TOOLBOX_CI_SKIP_VERIFY.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null  # lib is bats-tested directly (tekton-taskrun.bats)
. "$SCRIPT_DIR/lib/ci.sh"

TASK_FILE="${TOOLBOX_CI_TASK_FILE:-$SCRIPT_DIR/../tasks/buildkit-build.yaml}"
TEKTON_NS="${TOOLBOX_CI_TEKTON_NS:-tekton-pipelines}"
NS="$(ci_namespace)"

die() {
	echo "tekton-taskrun: $*" >&2
	exit 1
}
usage() {
	echo "usage: mise run ci:taskrun -- <context-dir> <dockerfile> <image-ref> [--keep|--teardown]" >&2
	exit 2
}

# --- args --------------------------------------------------------------
CLEANUP=auto # auto | keep | force
POSITIONAL=()
for arg in "$@"; do
	case "$arg" in
	--keep) CLEANUP=keep ;;
	--teardown) CLEANUP=force ;;
	-*) usage ;;
	*) POSITIONAL+=("$arg") ;;
	esac
done
[ "${#POSITIONAL[@]}" -eq 3 ] || usage
CONTEXT_DIR="${POSITIONAL[0]}"
DOCKERFILE_PATH="${POSITIONAL[1]}"
IMAGE_REF="${POSITIONAL[2]}"

[ -d "$CONTEXT_DIR" ] || die "context-dir is not a directory: $CONTEXT_DIR"
[ -f "$DOCKERFILE_PATH" ] || die "dockerfile is not a file: $DOCKERFILE_PATH"
[ -f "$TASK_FILE" ] || die "Task file not found: $TASK_FILE"
case "$IMAGE_REF" in
*@*) die "image-ref must be a bare repository, no digest: $IMAGE_REF" ;;
esac
case "${IMAGE_REF##*/}" in
*:*) die "image-ref must be a bare repository, no tag: $IMAGE_REF" ;;
esac
CONTEXT_DIR="$(cd "$CONTEXT_DIR" && pwd)"
DEFS_DIR="$(cd "$(dirname "$DOCKERFILE_PATH")" && pwd)"
DOCKERFILE_NAME="$(basename "$DOCKERFILE_PATH")"

# common_prefix — deepest directory that is a prefix of both absolute paths
# (component-wise, so /a/bc and /a/bcd share /a, not /a/bc). Both workspaces
# bind ONE PVC over this dir with different subPaths (Tekton forbids two
# distinct PVCs in a TaskRun); T7b's git-clone Task drops the constraint.
common_prefix() {
	local out="" i=0
	local -a pa pb
	IFS=/ read -r -a pa <<<"${1#/}"
	IFS=/ read -r -a pb <<<"${2#/}"
	while [ "$i" -lt "${#pa[@]}" ] && [ "$i" -lt "${#pb[@]}" ] && [ "${pa[$i]}" = "${pb[$i]}" ]; do
		out="$out/${pa[$i]}"
		i=$((i + 1))
	done
	printf '%s\n' "${out:-/}"
}
STAGE_ROOT="$(common_prefix "$CONTEXT_DIR" "$DEFS_DIR")"
[ "$STAGE_ROOT" != / ] ||
	die "context-dir and dockerfile must share a parent directory below / (got $CONTEXT_DIR and $DEFS_DIR)"
[ -d "$STAGE_ROOT" ] || die "no shared parent directory for context and dockerfile"
CTX_SUBPATH="${CONTEXT_DIR#"$STAGE_ROOT"/}"
DEFS_SUBPATH="${DEFS_DIR#"$STAGE_ROOT"/}"
[ "$CTX_SUBPATH" = "$CONTEXT_DIR" ] && CTX_SUBPATH="."
[ "$DEFS_SUBPATH" = "$DEFS_DIR" ] && DEFS_SUBPATH="."

# --- preflight (each fatal, names the fix) ----------------------------
echo "==> Preflight"
command -v kubectl >/dev/null || die "kubectl not on PATH — run \`mise install\`"
command -v tkn >/dev/null || die "tkn not on PATH — run \`mise install\`"
ci_require_context || exit 1
ci_kubectl -n "$TEKTON_NS" wait --for=condition=Available --timeout=5s \
	deployment/tekton-pipelines-controller >/dev/null 2>&1 ||
	die "Tekton Pipelines controller not Ready in ns/$TEKTON_NS — run \`mise run local:tekton:install\`"
ci_kubectl get namespace "$NS" >/dev/null 2>&1 ||
	die "namespace/$NS is missing — run \`kubectl --context $(ci_kube_context) apply -f $SCRIPT_DIR/../runtime/namespace.yaml\`"
GH_TOKEN_VALUE="$(gh auth token 2>/dev/null || true)"
[ -n "$GH_TOKEN_VALUE" ] ||
	die "\`gh auth token\` is empty — run \`gh auth login\` (scope: write:packages)"
GH_USER="$(gh api user --jq .login 2>/dev/null || true)"
[ -n "$GH_USER" ] || die "\`gh api user\` failed — re-auth with \`gh auth login\`"

# --- per-run identifiers --------------------------------------------
# Every object this run creates carries RUN_ID, so two concurrent runs —
# or two worktrees — never share a name, and teardown only ever names its
# own objects (never the namespace, never another run).
RUN_ID="$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"
SECRET_NAME="tekton-taskrun-${RUN_ID}-ghcr"
PV_STAGE="tekton-taskrun-${RUN_ID}-stage"
# The Task pushes under this tag; we resolve the manifest digest from it
# (`oras resolve`) and pin on the digest. A throwaway lookup handle —
# best-effort deleted on teardown; GC-able otherwise.
TAG="tekton-taskrun-${RUN_ID}"
CREATED=() # names to clean up, "kind/name"

# --- dry run (test seam) -------------------------------------------
# TOOLBOX_CI_DRY_RUN=1 — run preflight + arg validation, print the object
# names this run WOULD create, and exit 0 before touching the cluster.
if [ -n "${TOOLBOX_CI_DRY_RUN:-}" ]; then
	echo "dry-run: namespace=${NS} (kept always)"
	echo "dry-run: run-id=${RUN_ID}"
	echo "dry-run: would-create taskrun/tekton-taskrun-${RUN_ID}-<gen>"
	echo "dry-run: would-create secret/${SECRET_NAME}"
	echo "dry-run: would-create pvc/${PV_STAGE} pv/${PV_STAGE}"
	echo "dry-run: would-push ${IMAGE_REF}:${TAG} (tag resolved to a digest, then deleted)"
	echo "dry-run: stage-root=${STAGE_ROOT} source-subpath=${CTX_SUBPATH} build-defs-subpath=${DEFS_SUBPATH} dockerfile=${DOCKERFILE_NAME}"
	exit 0
fi

cleanup() {
	local rc=$1
	rm -f "${DCJ_FILE:-}" # the dockerconfigjson temp file, if a failure left it
	if [ "$CLEANUP" = keep ]; then
		echo "==> --keep: leaving ${#CREATED[@]} object(s): ${CREATED[*]:-none}"
		return
	fi
	if [ "$CLEANUP" = auto ] && [ "$rc" -ne 0 ]; then
		echo "==> build/verify failed — keeping this run's objects for inspection:" >&2
		printf '    %s\n' "${CREATED[@]:-none}" >&2
		echo "    clean up with: $0 ... --teardown   (or delete them by name)" >&2
		return
	fi
	echo "==> Tearing down this run's objects"
	local obj
	for obj in "${CREATED[@]:-}"; do
		[ -n "$obj" ] || continue
		case "$obj" in
		pv/*) ci_kubectl delete "$obj" --ignore-not-found --wait=false >/dev/null 2>&1 || true ;;
		*) ci_kubectl -n "$NS" delete "$obj" --ignore-not-found --wait=false >/dev/null 2>&1 || true ;;
		esac
	done
	# best-effort — the gh token may lack delete:packages; the tag is
	# GC-able and the digest is what everything pins on regardless.
	if command -v oras >/dev/null; then
		oras manifest delete --force "${IMAGE_REF}:${TAG}" >/dev/null 2>&1 || true
	fi
}
trap 'rc=$?; cleanup "$rc"; exit $rc' EXIT

# --- stage: ONE per-run hostPath PV + PVC over the shared parent --------
echo "==> Staging workspace (hostPath: $STAGE_ROOT)"
ci_kubectl apply -f - >/dev/null <<-YAML
	apiVersion: v1
	kind: PersistentVolume
	metadata:
	  name: ${PV_STAGE}
	  labels: { app.kubernetes.io/part-of: toolbox-ci, ci.toolbox/run: "${RUN_ID}" }
	spec:
	  capacity: { storage: 1Gi }
	  accessModes: ["ReadOnlyMany"]
	  persistentVolumeReclaimPolicy: Delete
	  storageClassName: ""
	  claimRef: { namespace: ${NS}, name: ${PV_STAGE} }
	  hostPath: { path: ${STAGE_ROOT} }
	---
	apiVersion: v1
	kind: PersistentVolumeClaim
	metadata:
	  name: ${PV_STAGE}
	  namespace: ${NS}
	  labels: { app.kubernetes.io/part-of: toolbox-ci, ci.toolbox/run: "${RUN_ID}" }
	spec:
	  accessModes: ["ReadOnlyMany"]
	  storageClassName: ""
	  volumeName: ${PV_STAGE}
	  resources: { requests: { storage: 1Gi } }
	YAML
CREATED+=("pvc/${PV_STAGE}" "pv/${PV_STAGE}")
echo "    source subPath=${CTX_SUBPATH} , build-defs subPath=${DEFS_SUBPATH}"

# One PVC bound to two workspaces via subPath (Tekton allows the same claim
# on multiple workspaces; it forbids two different PVCs). subPath is dropped
# when the dir IS the stage root.
ws_binding() { # <workspace-name> <subpath>
	if [ "$2" = "." ]; then
		printf '    - { name: %s, persistentVolumeClaim: { claimName: %s } }' "$1" "$PV_STAGE"
	else
		printf '    - { name: %s, persistentVolumeClaim: { claimName: %s }, subPath: %s }' "$1" "$PV_STAGE" "$2"
	fi
}
WS_SOURCE="$(ws_binding source "$CTX_SUBPATH")"
WS_DEFS="$(ws_binding build-defs "$DEFS_SUBPATH")"

# --- credential Secret (per run, from `gh auth token`) --------------
# A Secret with a single `config.json` key, written via a 0600 temp file —
# the buildkit step points DOCKER_CONFIG straight at the mounted workspace,
# so the key must be literally `config.json` (a kubernetes.io/dockerconfigjson
# Secret's `.dockerconfigjson` key would not match). `kubectl create secret`
# with a value flag is argv-visible; the file keeps the token off the
# command line and out of stdout.
echo "==> Creating push Secret secret/${SECRET_NAME} (user ${GH_USER})"
DCJ_FILE="$(mktemp)"
chmod 600 "$DCJ_FILE"
AUTH_B64="$(printf '%s:%s' "$GH_USER" "$GH_TOKEN_VALUE" | base64 | tr -d '\n')"
printf '{"auths":{"%s":{"auth":"%s"}}}' "${IMAGE_REF%%/*}" "$AUTH_B64" >"$DCJ_FILE"
ci_kubectl -n "$NS" create secret generic "$SECRET_NAME" \
	--from-file=config.json="$DCJ_FILE" >/dev/null
rm -f "$DCJ_FILE"
CREATED+=("secret/${SECRET_NAME}")

# --- apply the shared Task (immutable; params differ per run) -------
ci_kubectl -n "$NS" apply -f "$TASK_FILE" >/dev/null

# --- create the TaskRun with a captured name (never --last) --------
echo "==> Creating TaskRun"
TR_NAME="$(
	ci_kubectl -n "$NS" create -o name -f - <<-YAML
		apiVersion: tekton.dev/v1
		kind: TaskRun
		metadata:
		  generateName: tekton-taskrun-${RUN_ID}-
		  labels: { app.kubernetes.io/part-of: toolbox-ci, ci.toolbox/run: "${RUN_ID}" }
		spec:
		  taskRef: { name: buildkit-build }
		  params:
		    - { name: IMAGE, value: "${IMAGE_REF}" }
		    - { name: TAG, value: "${TAG}" }
		    - { name: DOCKERFILE, value: "${DOCKERFILE_NAME}" }
		  podTemplate:
		    automountServiceAccountToken: false
		  workspaces:
		${WS_SOURCE}
		${WS_DEFS}
		    - { name: dockerconfig, secret: { secretName: ${SECRET_NAME} } }
	YAML
)"
TR_NAME="${TR_NAME#*/}"
CREATED=("taskrun/${TR_NAME}" "${CREATED[@]}") # delete the run before its volumes
echo "    taskrun/${TR_NAME}"

# --- stream ---------------------------------------------------------
echo "==> Streaming logs"
tkn --context "$(ci_kube_context)" -n "$NS" taskrun logs "$TR_NAME" -f || true

# --- wait for terminal state --------------------------------------
ci_kubectl -n "$NS" wait --for=condition=Succeeded --timeout=5s "taskrun/${TR_NAME}" >/dev/null 2>&1 || true
SUCCEEDED="$(ci_kubectl -n "$NS" get "taskrun/${TR_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')"
[ "$SUCCEEDED" = True ] || {
	REASON="$(ci_kubectl -n "$NS" get "taskrun/${TR_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}')"
	die "TaskRun did not succeed (reason: ${REASON:-unknown})"
}

# --- verify (Step-1 spike criteria) ------------------------------
if [ -n "${TOOLBOX_CI_SKIP_VERIFY:-}" ]; then
	echo "==> TOOLBOX_CI_SKIP_VERIFY set — skipping image verification"
	echo "tekton-taskrun: TaskRun ${TR_NAME} Succeeded"
	exit 0
fi

echo "==> Verifying result"
command -v oras >/dev/null || die "oras not on PATH — run \`mise install\`"
DIGEST="$(oras resolve "${IMAGE_REF}:${TAG}" 2>/dev/null || true)"
ci_is_strict_digest "$DIGEST" ||
	die "could not resolve a strict sha256 digest for ${IMAGE_REF}:${TAG} (got: '${DIGEST}') — is the package readable? try \`oras login ${IMAGE_REF%%/*}\`"
REF="${IMAGE_REF}@${DIGEST}"
echo "    digest: ${DIGEST}  (resolved from :${TAG})"

# architecture lives in the image CONFIG blob, not the manifest
CONFIG="$(oras manifest fetch-config "$REF" 2>/dev/null || true)"
case "$CONFIG" in
*'"architecture":"arm64"'*) echo "    oras: image config arch=arm64" ;;
"") die "oras could not fetch the image config for ${REF}" ;;
*) die "image ${REF} is not arm64: $(printf '%s' "$CONFIG" | grep -o '"architecture":"[^\"]*"' | head -n1)" ;;
esac

if command -v docker >/dev/null; then
	docker pull --quiet "$REF" >/dev/null || die "docker pull ${REF} failed"
	echo "    docker pull: ok"
fi

POD="$(ci_kubectl -n "$NS" get "taskrun/${TR_NAME}" -o jsonpath='{.status.podName}')"
PRIV="$(ci_kubectl -n "$NS" get "pod/${POD}" -o jsonpath='{.spec.containers[*].securityContext.privileged}')"
CAPS="$(ci_kubectl -n "$NS" get "pod/${POD}" -o jsonpath='{.spec.containers[*].securityContext.capabilities.add}')"
case "$PRIV" in *true*) die "build pod ${POD} ran a privileged container" ;; esac
case "$CAPS" in *SYS_ADMIN* | *SYS_PTRACE*) die "build pod ${POD} added SYS_ADMIN/SYS_PTRACE" ;; esac
echo "    pod securityContext: no privileged, no SYS_ADMIN/SYS_PTRACE"

echo "tekton-taskrun: OK — ${REF}"
