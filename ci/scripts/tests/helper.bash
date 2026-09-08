# ci/ test fixtures. The concern-agnostic half (scratch-dir copy, free
# ports, a throwaway registry) lives in tests/lib/ and is loaded below.
# What stays here is ci-specific: a fake-bin PATH shim (stub kubectl) for
# the chainsaw-test.sh skip-decision cases.
#
# There is NO [k8s] bats case: the fake-bin shim would fake a cluster gate
# true and then the test would exec the REAL chainsaw/kubectl (a
# GitHub-runner failure, not a skip). Real end-to-end coverage is the hk
# `chainsaw` step itself (`./ci/scripts/chainsaw-test.sh` — skips in CI on
# the missing orbstack context, runs the live cluster locally) and an
# operator `tkn pipeline start` (recorded in TODOS.md T7b1).

# --- load the shared test lib (per-dir loader, no BATS_LIB_PATH) --------
_d="$BATS_TEST_DIRNAME"
while [ "$_d" != "/" ] && [ ! -e "$_d/mise.toml" ]; do _d="$(dirname "$_d")"; done
# shellcheck source=/dev/null
. "$_d/tests/lib/ports.bash"
# shellcheck source=/dev/null
. "$_d/tests/lib/scratch.bash"
# exported for the .bats files that `load helper` (SC2034: used externally).
export CI_SCRIPTS="$_d/ci/scripts"
export CI_LIB="$_d/ci/scripts/lib/ci.sh"
unset _d

# --- fake-bin PATH shim for the chainsaw skip-decision cases ----------
# A stub kubectl whose behaviour each test tweaks via STUB_* env vars;
# the default is a healthy, reachable cluster with Tekton installed.
fakebin_setup() {
	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$FAKEBIN"

	cat >"$FAKEBIN/kubectl" <<-'SH'
		#!/usr/bin/env bash
		set -eu
		case "$*" in
		*"config get-contexts -o name"*)
		  printf '%s\n' ${STUB_KUBECTL_CONTEXTS-orbstack} ; exit 0 ;;
		*"cluster-info"*)              exit "${STUB_KUBECTL_CLUSTERINFO_RC:-0}" ;;
		*tekton-pipelines-controller*) exit "${STUB_KUBECTL_TEKTON_RC:-0}" ;;
		*) exit 0 ;;
		esac
	SH

	chmod +x "$FAKEBIN"/kubectl
	PATH="$FAKEBIN:$PATH"
}
