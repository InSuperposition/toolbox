#!/usr/bin/env bats

# ci/scripts/ci-taskrun.sh + lib/ci.sh — the pure-shell half: the strict
# digest guard and every preflight failure path. Each preflight case runs
# the real script against a fake-bin kubectl/tkn/gh (helper.bash
# fakebin_setup) so no cluster is needed and CI runs them.
#
# The in-cluster behaviour (TaskRun Succeeded + sha256 result + arm64 +
# no privileged pod) is covered by ci/tests/buildkit-build.chainsaw.yaml
# ([k8s]-gated) and the manual `mise run ci:taskrun`.

setup() {
	load helper
	fakebin_setup

	CTX_DIR="$BATS_TEST_TMPDIR/context"
	DEFS_DIR="$BATS_TEST_TMPDIR/defs"
	mkdir -p "$CTX_DIR" "$DEFS_DIR"
	printf 'FROM scratch\n' >"$DEFS_DIR/Dockerfile"
	DF="$DEFS_DIR/Dockerfile"
	IMG="ghcr.io/example/app"

	export TOOLBOX_CI_KUBE_CONTEXT=orbstack
}

run_taskrun() { run "$CI_SCRIPTS/ci-taskrun.sh" "$CTX_DIR" "$DF" "$IMG"; }

# --- strict digest guard (lib/ci.sh) --------------------------------

@test "ci_is_strict_digest accepts sha256: + exactly 64 lowercase hex" {
	run bash -c ". '$CI_LIB'; ci_is_strict_digest sha256:$(printf 'a%.0s' {1..64})"
	[ "$status" -eq 0 ]
}

@test "ci_is_strict_digest rejects empty, a tag, short, and uppercase" {
	local bad
	for bad in "" "latest" "v1.2.3" "sha256:abc123" \
		"sha256:$(printf 'a%.0s' {1..63})" \
		"sha256:$(printf 'A%.0s' {1..64})" \
		"$(printf 'a%.0s' {1..64})"; do
		run bash -c ". '$CI_LIB'; ci_is_strict_digest '$bad'"
		[ "$status" -ne 0 ] || {
			echo "expected reject: [$bad]"
			return 1
		}
	done
}

# --- argument handling ---------------------------------------------

@test "bad arguments -> exit 2 with usage" {
	run "$CI_SCRIPTS/ci-taskrun.sh" only one
	[ "$status" -eq 2 ]
	[[ "$output" == *"usage:"* ]]
}

@test "an image-ref with a tag is rejected -> exit 1" {
	run "$CI_SCRIPTS/ci-taskrun.sh" "$CTX_DIR" "$DF" "ghcr.io/example/app:latest"
	[ "$status" -eq 1 ]
	[[ "$output" == *"no tag"* ]]
}

# --- preflight failure paths -------------------------------------

@test "kube-context absent from the kubeconfig -> exit 1, names it" {
	STUB_KUBECTL_CONTEXTS="docker-desktop minikube" run_taskrun
	[ "$status" -eq 1 ]
	[[ "$output" == *"kube-context 'orbstack' not in the kubeconfig"* ]]
}

@test "kube-context unreachable -> exit 1, names it" {
	STUB_KUBECTL_CLUSTERINFO_RC=1 run_taskrun
	[ "$status" -eq 1 ]
	[[ "$output" == *"unreachable"* ]]
}

@test "Tekton controller not Ready -> exit 1, points at local:tekton:install" {
	STUB_KUBECTL_TEKTON_RC=1 run_taskrun
	[ "$status" -eq 1 ]
	[[ "$output" == *"local:tekton:install"* ]]
}

@test "empty gh token -> exit 1, names write:packages" {
	STUB_GH_TOKEN="" run_taskrun
	[ "$status" -eq 1 ]
	[[ "$output" == *"write:packages"* ]]
}

@test "the gh token value never appears in output" {
	STUB_GH_TOKEN="ghs_supersecret_value" TOOLBOX_CI_DRY_RUN=1 run_taskrun
	[ "$status" -eq 0 ]
	[[ "$output" != *"ghs_supersecret_value"* ]]
}

# --- per-run naming (dry run, no cluster) -----------------------

@test "dry-run: every object carries the run id; the namespace is never in the create list" {
	TOOLBOX_CI_DRY_RUN=1 run_taskrun
	[ "$status" -eq 0 ]
	local rid
	rid="$(sed -n 's/^dry-run: run-id=//p' <<<"$output")"
	[ -n "$rid" ]
	# every would-create line names the run id
	while IFS= read -r line; do
		[[ "$line" == *"$rid"* ]] || {
			echo "no run id in: $line"
			return 1
		}
	done < <(grep '^dry-run: would-create' <<<"$output")
	# teardown never targets the namespace itself
	[[ "$output" != *"would-create namespace"* ]]
	[[ "$output" == *"namespace=ci (kept always)"* ]]
}

@test "dry-run: two runs produce disjoint object names" {
	TOOLBOX_CI_DRY_RUN=1 run_taskrun
	local a
	a="$(grep '^dry-run: would-create' <<<"$output")"
	TOOLBOX_CI_DRY_RUN=1 run_taskrun
	local b
	b="$(grep '^dry-run: would-create' <<<"$output")"
	[ -n "$a" ] && [ -n "$b" ]
	[ "$a" != "$b" ]
}
