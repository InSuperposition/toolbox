#!/usr/bin/env bats

# frontend-build.sh — `mise run frontend:build -- <sha>`. Drives the
# in-cluster build/scan/gate PipelineRun. Every cluster/registry/git/mise
# call is a stub (helper.bash build_fakebin); `cue` is real, so these
# render the actual deploy/frontend/pipelinerun.cue. The real end-to-end
# run is TODOS.md T7b3 (an operator `mise run frontend:build`), the same
# way T7b1/T7b2 recorded their live proofs.

setup() {
	load helper
	build_fakebin
	SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	# Default: valid SHA, immediate terminal state, no polling delay.
	REV=abc1234
	export TOOLBOX_BUILD_POLL_INTERVAL=0
}

# --- argument validation --------------------------------------------------

@test "frontend-build: no argument -> usage, exit 2" {
	run "$SCRIPTS/frontend-build.sh"
	[ "$status" -eq 2 ]
	[[ "$output" == *"usage: mise run frontend:build"* ]]
}

@test "frontend-build: non-hex SHA -> exit 2, no kubectl" {
	run "$SCRIPTS/frontend-build.sh" ZZZZ123
	[ "$status" -eq 2 ]
	[[ "$output" == *"not a git SHA"* ]]
	[ ! -s "$KLOG" ]
}

@test "frontend-build: too-short SHA -> exit 2" {
	run "$SCRIPTS/frontend-build.sh" abc
	[ "$status" -eq 2 ]
}

@test "frontend-build: too many arguments -> exit 2" {
	run "$SCRIPTS/frontend-build.sh" abc1234 def5678
	[ "$status" -eq 2 ]
}

# --- preflight (each prerequisite, its own fix hint, exit 3) -------------

@test "frontend-build: unreachable cluster -> exit 3" {
	STUB_CLUSTERINFO_RC=1 run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 3 ]
	[[ "$output" == *"unreachable"* ]]
}

@test "frontend-build: Pipeline missing -> exit 3, points at the Flux reconcile path" {
	STUB_NO_PIPELINE=1 run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 3 ]
	[[ "$output" == *"local:tekton:install"* ]]
	[[ "$output" == *"local:flux:bootstrap"* ]]
}

@test "frontend-build: Pipeline present but has no 'gate' task -> exit 3" {
	STUB_PIPELINE_TASKS="clone-app clone-defs build scan-attach" \
		run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 3 ]
	[[ "$output" == *"no 'gate' task"* ]]
}

@test "frontend-build: buildkitd-mirror ConfigMap missing -> exit 3, points at the Flux reconcile path" {
	STUB_NO_CM=1 run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 3 ]
	[[ "$output" == *"buildkitd-mirror"* ]]
	[[ "$output" == *"local:flux:bootstrap"* ]]
}

@test "frontend-build: zot down -> exit 3, points at the Flux reconcile path" {
	STUB_ZOT_RC=7 run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 3 ]
	[[ "$output" == *"local:flux:bootstrap"* ]]
	[[ "$output" == *"local:tekton:install"* ]]
}

@test "frontend-build: base-image seed failure -> exit 3" {
	STUB_SEED_RC=4 run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 3 ]
	[[ "$output" == *"seed failed"* ]]
}

# --- render -------------------------------------------------------------

@test "frontend-build: the created manifest is namespaced ci with a 15m timeout" {
	run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 0 ]
	grep -q 'namespace: ci' "$CREATE_STDIN"
	grep -q 'pipeline: 15m' "$CREATE_STDIN"
	grep -q "value: $REV" "$CREATE_STDIN"
}

@test "frontend-build: TOOLBOX_DEFS_REF overrides the defs revision in the manifest" {
	TOOLBOX_DEFS_REF=deadbeefcafe run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 0 ]
	grep -q 'value: deadbeefcafe' "$CREATE_STDIN"
}

@test "frontend-build: the rendered PipelineRun validates against the vendored CRD schema" {
	root="$(toolbox_repo_root)"
	run bash -c "cue export '$root/deploy/frontend/pipelinerun.cue' -e pipelineRun \
		-t rev=deadbeef -t defsRev=deadbeef --out yaml \
		| kubeconform -strict -summary -schema-location default \
		  -schema-location '$root/ci/tests/crd-schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' -"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Valid: 1"* ]]
}

# --- every kubectl / tkn call is context+namespace pinned (A3) ----------

@test "frontend-build: every kubectl call carries --context and -n ci" {
	run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 0 ]
	[ -s "$KLOG" ]
	! grep -qve '--context' "$KLOG"
	! grep -qve '-n ci' "$KLOG"
}

@test "frontend-build: every tkn call carries --context and -n ci" {
	run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 0 ]
	[ -s "$TLOG" ]
	! grep -qve '--context' "$TLOG"
	! grep -qve '-n ci' "$TLOG"
}

# --- success ----------------------------------------------------------

@test "frontend-build: Succeeded -> prints the digest, the sign line, deletes the run" {
	run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 0 ]
	a64="$(printf 'a%.0s' {1..64})"
	[[ "$output" == *"BUILT  localhost:30500/cv-frontend@sha256:$a64"* ]]
	[[ "$output" == *"mise run attestation:sign -- localhost:30500/cv-frontend@sha256:$a64"* ]]
	grep -q 'delete pipelinerun' "$KLOG"
}

@test "frontend-build: Succeeded -> prints this run's trivy scan-report referrer digest (A5)" {
	run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 0 ]
	b64="$(printf 'b%.0s' {1..64})"
	[[ "$output" == *"scan-report referrer"* ]]
	[[ "$output" == *"sha256:$b64"* ]]
}

@test "frontend-build: Succeeded but oras resolve returns a tag -> exit 5, run NOT deleted" {
	STUB_DIGEST="latest" run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 5 ]
	[[ "$output" == *"not a canonical sha256"* ]]
	! grep -q 'delete pipelinerun' "$KLOG"
}

@test "frontend-build: Succeeded but oras resolve returns an uppercase digest -> exit 5" {
	STUB_DIGEST="sha256:$(printf 'A%.0s' {1..64})" run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 5 ]
}

# --- failure (run kept, gate exitCode classifies the message) -----------

@test "frontend-build: gate step exitCode 2 -> the loud CRITICAL box, exit 1, run kept" {
	STUB_PR_STATUS=False STUB_PR_REASON=Failed STUB_GATE_EXIT=2 \
		run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 1 ]
	[[ "$output" == *"CRITICAL vulnerability"* ]]
	[[ "$output" == *"DELIBERATE"* ]]
	! grep -q 'delete pipelinerun' "$KLOG"
}

@test "frontend-build: gate step exitCode 1 -> 'gate ERRORED, not a verdict', exit 1" {
	STUB_PR_STATUS=False STUB_PR_REASON=Failed STUB_GATE_EXIT=1 \
		run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 1 ]
	[[ "$output" == *"ERRORED"* ]]
	[[ "$output" == *"NOT a vulnerability verdict"* ]]
}

@test "frontend-build: a non-gate task failure -> 'failed before the gate ran', exit 1" {
	STUB_PR_STATUS=False STUB_PR_REASON=Failed STUB_GATE_TR="" \
		run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 1 ]
	[[ "$output" == *"before the gate ran"* ]]
}

# --- watch bound + dirty-Dockerfile warning ----------------------------

@test "frontend-build: PipelineRun never leaves Unknown before the deadline -> exit 1, run kept" {
	STUB_PR_STATUS=Unknown TOOLBOX_BUILD_POLL_DEADLINE=0 \
		run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 1 ]
	[[ "$output" == *"did not reach a terminal state"* ]]
	! grep -q 'delete pipelinerun' "$KLOG"
}

@test "frontend-build: a dirty Dockerfile at the defs ref warns but still builds" {
	STUB_DOCKERFILE_DIRTY=1 run "$SCRIPTS/frontend-build.sh" "$REV"
	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING"* ]]
	[[ "$output" == *"local edits will NOT be in the build"* ]]
}
