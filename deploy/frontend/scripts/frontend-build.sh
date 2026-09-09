#!/usr/bin/env bash
set -euo pipefail

# `mise run frontend:build -- <cv_frontend-sha>`
#
# The operator entrypoint for the in-cluster build/scan/gate pipeline. One
# argument — the cv_frontend commit SHA to build. It:
#
#   1. preflights the cluster prerequisites (context, Pipeline + gate task,
#      buildkitd mirror CM, zot, seeded base images),
#   2. renders deploy/frontend/pipelinerun.cue with the SHA + the toolbox
#      defs ref injected as CUE tags (fails closed on a missing/!hex SHA),
#   3. `kubectl create`s the PipelineRun and polls it to a terminal state,
#   4. on success: resolves the pushed manifest digest, prints this run's
#      trivy scan-report referrer digest, deletes the run, and hands the
#      operator the exact `attestation:sign` line,
#   5. on failure: leaves the run + pods for inspection and, if the `gate`
#      step is what failed, says whether it was a CRITICAL verdict
#      (exitCode 2 — signing would be a deliberate override) or a gate
#      ERROR (exitCode 1 — malformed scan.json / pull failure, NOT a
#      verdict).
#
# The digest is resolved once, here, by the operator — never a Tekton
# result (ADR 0001, the tag-addressed flow). Human approval
# (`attestation:sign`) and consumption (`frontend:deploy`) stay outside.
#
# deploy/frontend may NOT depend on ci/ (repo-structure.md § concerns): the
# Pipeline is referenced by NAME (cluster-side resolution), the strict-digest
# check is inlined in lib/frontend.sh, and a base-image reseed goes through
# the `frontend:seed` mise task, never a source of ci/scripts/.
#
# Env overrides:
#   TOOLBOX_DEFS_REF      toolbox git ref for the Dockerfile (default: HEAD)
#   TOOLBOX_KUBE_CONTEXT  kube-context to pin (default: orbstack)
#
# Exit: 0 built + approved-next  · 1 pipeline failed (run kept)
#       2 bad arguments          · 3 a preflight prerequisite is missing
#       5 the resolved digest is not a canonical sha256

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null  # lib is exercised via frontend-build.bats
. "$SCRIPT_DIR/lib/frontend.sh"

ROOT="$(frontend_repo_root)"
CUE_FILE="$ROOT/deploy/frontend/pipelinerun.cue"
POLL_INTERVAL="${TOOLBOX_BUILD_POLL_INTERVAL:-10}"  # seconds between status reads
POLL_DEADLINE="${TOOLBOX_BUILD_POLL_DEADLINE:-960}" # ~16m — pipeline self-times-out at 15m

die() {
	echo "frontend-build: $*" >&2
	exit 1
}
miss() {
	echo "frontend-build: $*" >&2
	exit 3
}

# --- 0. argument ---------------------------------------------------------
if [ $# -ne 1 ]; then
	echo "usage: mise run frontend:build -- <cv_frontend-sha>" >&2
	exit 2
fi
REV="$1"
case "$REV" in
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
*)
	echo "frontend-build: '$REV' is not a git SHA (need 7-40 lowercase hex)" >&2
	exit 2
	;;
esac
[ "${#REV}" -ge 7 ] && [ "${#REV}" -le 40 ] && [ -z "${REV//[0-9a-f]/}" ] ||
	{
		echo "frontend-build: '$REV' is not a git SHA (need 7-40 lowercase hex)" >&2
		exit 2
	}

DEFS_REF="${TOOLBOX_DEFS_REF:-$(git -C "$ROOT" rev-parse HEAD)}"

# --- 1. preflight ------------------------------------------------------
frontend_kube cluster-info >/dev/null 2>&1 ||
	miss "kube-context '$(frontend_kube_context)' is unreachable — is \`orb start k8s\` up?"

pipeline_tasks="$(frontend_kube get pipeline build-scan-approve \
	-o jsonpath='{.spec.tasks[*].name}' 2>/dev/null || true)"
case " $pipeline_tasks " in
*" gate "*) ;;
*)
	miss "Pipeline build-scan-approve is absent or has no 'gate' task — apply the ci/ defs:
  kubectl --context $(frontend_kube_context) -n ci apply -f ci/tasks -f ci/pipelines"
	;;
esac

frontend_kube get configmap buildkitd-mirror >/dev/null 2>&1 ||
	miss "ConfigMap buildkitd-mirror is missing in ns ci — apply it:
  kubectl --context $(frontend_kube_context) -n ci apply -f ci/runtime/buildkitd-mirror.yaml"

curl -sf -o /dev/null http://localhost:30500/v2/ ||
	miss "zot is not answering on localhost:30500 — Flux reconciles it: \`mise run local:flux:bootstrap\` (once) then \`mise run local:zot:wait\`"

# Base images: reseed is idempotent (crane copy skips manifests already
# present), so just run it. Uses the WORKING-TREE Dockerfile — the dirty
# check below warns when that differs from the ref the pipeline will clone.
echo "frontend-build: ensuring cv_frontend base images are in zot (mise run frontend:seed)"
mise run frontend:seed || miss "base-image seed failed — see the crane output above"

if ! git -C "$ROOT" diff --quiet "$DEFS_REF" -- deploy/frontend/Dockerfile 2>/dev/null; then
	echo "frontend-build: WARNING — deploy/frontend/Dockerfile differs from $DEFS_REF;" >&2
	echo "  the pipeline clones that ref, so your local edits will NOT be in the build." >&2
fi

echo "frontend-build: building cv_frontend@$REV with toolbox@$DEFS_REF / deploy/frontend/Dockerfile"

# --- 2. render --------------------------------------------------------
rendered="$(cue export "$CUE_FILE" -e pipelineRun \
	-t rev="$REV" -t defsRev="$DEFS_REF" --out yaml)" ||
	die "cue export failed — the SHA or defs ref did not satisfy the schema"

# --- 3. create + watch ----------------------------------------------
name="$(printf '%s\n' "$rendered" | frontend_kube create -f - -o name)" ||
	die "kubectl create PipelineRun failed"
name="${name#*/}"
echo "frontend-build: created PipelineRun $name"

frontend_tkn pipelinerun logs -f "$name" 2>/dev/null &
logs_pid=$!

status=""
deadline=$(($(date +%s) + POLL_DEADLINE))
while :; do
	status="$(frontend_kube get pipelinerun "$name" \
		-o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)"
	[ -n "$status" ] && [ "$status" != "Unknown" ] && break
	if [ "$(date +%s)" -ge "$deadline" ]; then
		kill "$logs_pid" 2>/dev/null || true
		echo "frontend-build: PipelineRun $name did not reach a terminal state within ${POLL_DEADLINE}s" >&2
		echo "  the run is kept — inspect: frontend-build keeps it, see \`tkn -n ci pr logs $name\`" >&2
		exit 1
	fi
	sleep "$POLL_INTERVAL"
done
kill "$logs_pid" 2>/dev/null || true

reason="$(frontend_kube get pipelinerun "$name" \
	-o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || true)"

# --- 4. success ------------------------------------------------------
if [ "$status" = "True" ]; then
	host_image="$(frontend_host_image)"

	scan_refs="$(oras discover --plain-http --format json "${host_image}:${REV}" 2>/dev/null |
		jq -r '(.referrers // .manifests // [])[]
		       | select(.artifactType == "application/vnd.trivy.report+json") | .digest' || true)"

	digest="$(oras resolve --plain-http "${host_image}:${REV}")" ||
		die "oras resolve failed for ${host_image}:${REV}"
	frontend_strict_digest "$digest" ||
		{
			echo "frontend-build: resolved '$digest' is not a canonical sha256:<64hex>" >&2
			exit 5
		}

	frontend_kube delete pipelinerun "$name" >/dev/null 2>&1 || true

	echo
	echo "frontend-build: BUILT  ${host_image}@${digest}"
	if [ -n "$scan_refs" ]; then
		echo "  trivy scan-report referrer(s) for this tag:"
		while IFS= read -r ref; do echo "    $ref"; done <<<"$scan_refs"
		[ "$(printf '%s\n' "$scan_refs" | wc -l)" -gt 1 ] &&
			echo "    (>1 — a byte-identical rebuild; the newest is this run's evidence)"
	fi
	echo
	echo "  APPROVE NEXT →"
	echo "    mise run attestation:sign -- ${host_image}@${digest}"
	exit 0
fi

# --- 5. failure (run kept) -----------------------------------------
gate_tr="$(frontend_kube get pipelinerun "$name" \
	-o jsonpath='{.status.childReferences[?(@.pipelineTaskName=="gate")].name}' 2>/dev/null || true)"
gate_exit=""
if [ -n "$gate_tr" ]; then
	gate_exit="$(frontend_kube get taskrun "$gate_tr" \
		-o jsonpath='{.status.steps[?(@.name=="gate")].terminated.exitCode}' 2>/dev/null || true)"
fi

echo >&2
case "$gate_exit" in
2)
	echo "  ┌──────────────────────────────────────────────────────────┐" >&2
	echo "  │  GATE FAILED — a CRITICAL vulnerability was found          │" >&2
	echo "  │  Signing an approval for this digest is a DELIBERATE       │" >&2
	echo "  │  override. attestation:sign needs a real reason in the    │" >&2
	echo "  │  record.                                                  │" >&2
	echo "  └──────────────────────────────────────────────────────────┘" >&2
	;;
1)
	echo "frontend-build: the gate task ERRORED (malformed scan.json / pull failure / eviction)" >&2
	echo "  — this is NOT a vulnerability verdict. See the logs." >&2
	;;
*)
	echo "frontend-build: PipelineRun $name failed (${reason:-unknown}) before the gate ran" >&2
	;;
esac
echo "  the run is kept for inspection:" >&2
echo "    tkn --context $(frontend_kube_context) -n ci pipelinerun logs $name" >&2
echo "    kubectl --context $(frontend_kube_context) -n ci describe pipelinerun $name" >&2
exit 1
