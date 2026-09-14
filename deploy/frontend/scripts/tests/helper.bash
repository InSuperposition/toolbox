# deploy/frontend test fixtures. The concern-agnostic half (repo-root
# resolution) lives in tests/lib/ and is loaded below. What stays here is
# frontend-specific: the frontend-build.sh fake-bin PATH shim.

# --- load the shared test lib (per-dir loader, no BATS_LIB_PATH / mise env) -
_d="$BATS_TEST_DIRNAME"
while [ "$_d" != "/" ] && [ ! -e "$_d/mise.toml" ]; do _d="$(dirname "$_d")"; done
# shellcheck source=/dev/null
. "$_d/tests/lib/scratch.bash"
unset _d

# --- frontend-build.sh fake-bin PATH shim (T7b3) --------------------------
# frontend-build.sh drives a real cluster (kubectl/tkn) + registry (oras) +
# git + the frontend:seed mise task. None of that belongs in a pre-merge
# gate, so every one is a stub whose behaviour each test tweaks via STUB_*
# env vars; the default is a clean, healthy, Succeeded run. `cue` is NOT
# stubbed — the tests render the real deploy/frontend/pipelinerun.cue.
#
# Logs: $KLOG / $TLOG / $OLOG / $MLOG capture argv per line (assert that
# every kubectl/tkn call carried `-n ci` + `--context`); $CREATE_STDIN
# holds the exact manifest piped to `kubectl create -f -`.
build_fakebin() {
	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	KLOG="$BATS_TEST_TMPDIR/kubectl.log"
	TLOG="$BATS_TEST_TMPDIR/tkn.log"
	OLOG="$BATS_TEST_TMPDIR/oras.log"
	MLOG="$BATS_TEST_TMPDIR/mise.log"
	CREATE_STDIN="$BATS_TEST_TMPDIR/create-stdin.yaml"
	mkdir -p "$FAKEBIN"
	: >"$KLOG"
	: >"$TLOG"
	: >"$OLOG"
	: >"$MLOG"

	cat >"$FAKEBIN/kubectl" <<-'SH'
		#!/usr/bin/env bash
		set -eu
		echo "$*" >>"$KLOG"
		case "$*" in
		*"cluster-info"*) exit "${STUB_CLUSTERINFO_RC:-0}" ;;
		*"get pipeline build-scan-approve"*)
			[ -n "${STUB_NO_PIPELINE:-}" ] && exit 1
			printf '%s' "${STUB_PIPELINE_TASKS-clone-app clone-defs build scan-attach gate}"; exit 0 ;;
		*"get configmap buildkitd-mirror"*)
			[ -n "${STUB_NO_CM:-}" ] && exit 1
			exit 0 ;;
		*"create -f -"*)
			cat >"$CREATE_STDIN"
			[ -n "${STUB_CREATE_RC:-}" ] && exit "$STUB_CREATE_RC"
			echo "pipelinerun.tekton.dev/${STUB_PR_NAME:-cv-frontend-t3st1}"; exit 0 ;;
		*"get pipelinerun"*".status}"*)  printf '%s' "${STUB_PR_STATUS:-True}"; exit 0 ;;
		*"get pipelinerun"*".reason}"*)  printf '%s' "${STUB_PR_REASON:-Succeeded}"; exit 0 ;;
		*"get pipelinerun"*"IMAGE_DIGEST"*)
			h64="$(printf 'a%.0s' {1..64})"
			printf '%s' "${STUB_DIGEST:-sha256:$h64}"; exit 0 ;;
		*"get pipelinerun"*"childReferences"*) printf '%s' "${STUB_GATE_TR-cv-frontend-t3st1-gate}"; exit 0 ;;
		*"get taskrun"*)  printf '%s' "${STUB_GATE_EXIT-2}"; exit 0 ;;
		*"delete pipelinerun"*) exit 0 ;;
		*) exit 0 ;;
		esac
	SH

	cat >"$FAKEBIN/tkn" <<-'SH'
		#!/usr/bin/env bash
		set -eu
		echo "$*" >>"$TLOG"
		exit 0
	SH

	cat >"$FAKEBIN/oras" <<-'SH'
		#!/usr/bin/env bash
		set -eu
		echo "$*" >>"$OLOG"
		s64="$(printf 'b%.0s' {1..64})"
		default_discover='{"referrers":[{"artifactType":"application/vnd.trivy.report+json","digest":"sha256:'"$s64"'"}]}'
		case "$*" in
		*discover*) printf '%s' "${STUB_ORAS_DISCOVER:-$default_discover}"; exit 0 ;;
		*) exit 0 ;;
		esac
	SH

	cat >"$FAKEBIN/git" <<-'SH'
		#!/usr/bin/env bash
		set -eu
		case "$*" in
		*"rev-parse HEAD"*) printf '%s\n' "${STUB_HEAD:-$(printf 'c%.0s' {1..40})}"; exit 0 ;;
		*"diff --quiet"*)   [ -n "${STUB_DOCKERFILE_DIRTY:-}" ] && exit 1; exit 0 ;;
		*) exit 0 ;;
		esac
	SH

	cat >"$FAKEBIN/mise" <<-'SH'
		#!/usr/bin/env bash
		set -eu
		echo "$*" >>"$MLOG"
		case "$*" in
		*"frontend:seed"*) exit "${STUB_SEED_RC:-0}" ;;
		*) exit 0 ;;
		esac
	SH

	cat >"$FAKEBIN/curl" <<-'SH'
		#!/usr/bin/env bash
		set -eu
		case "$*" in
		*"zot.zot.svc.cluster.local:5000/v2/"*) exit "${STUB_ZOT_RC:-0}" ;;
		*) exit 0 ;;
		esac
	SH

	chmod +x "$FAKEBIN"/kubectl "$FAKEBIN"/tkn "$FAKEBIN"/oras \
		"$FAKEBIN"/git "$FAKEBIN"/mise "$FAKEBIN"/curl
	export KLOG TLOG OLOG MLOG CREATE_STDIN
	PATH="$FAKEBIN:$PATH"
}
