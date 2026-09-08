# ci/ test fixtures. The concern-agnostic half (scratch-dir copy, free
# ports, a throwaway registry) lives in tests/lib/ and is loaded below.
# What stays here is ci-specific: a fake-bin PATH shim (stub
# kubectl/tkn/gh) for the preflight + skip-decision unit cases.
#
# There is NO [k8s] bats case: the fake-bin shim would fake a cluster gate
# true and then the test would exec the REAL chainsaw/kubectl (a
# GitHub-runner failure, not a skip). Real end-to-end coverage is the hk
# `chainsaw` step itself (`./ci/scripts/ci-chainsaw.sh` — skips in CI on
# the missing orbstack context, runs the live cluster locally) and
# `mise run ci:taskrun`.

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

# --- fake-bin PATH shim for the preflight unit cases ------------------
# Writes stub kubectl / tkn / gh into $FAKEBIN and prepends it to PATH.
# Each stub reads STUB_* env vars set by the test; default behaviour is a
# healthy cluster with a valid token, so a test overrides only the one
# thing it is exercising.
fakebin_setup() {
	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$FAKEBIN"

	cat >"$FAKEBIN/kubectl" <<-'SH'
		#!/usr/bin/env bash
		set -eu
		case "$*" in
		*"config get-contexts -o name"*)
		  printf '%s\n' ${STUB_KUBECTL_CONTEXTS-orbstack} ; exit 0 ;;
		*"cluster-info"*)                 exit "${STUB_KUBECTL_CLUSTERINFO_RC:-0}" ;;
		*tekton-pipelines-controller*)    exit "${STUB_KUBECTL_TEKTON_RC:-0}" ;;
		*"get namespace"*)                exit "${STUB_KUBECTL_NS_RC:-0}" ;;
		*) exit 0 ;;
		esac
	SH

	cat >"$FAKEBIN/tkn" <<-'SH'
		#!/usr/bin/env bash
		exit 0
	SH

	cat >"$FAKEBIN/gh" <<-'SH'
		#!/usr/bin/env bash
		set -eu
		case "$*" in
		"auth token") printf '%s' "${STUB_GH_TOKEN-ghs_faketoken}" ;;
		"api user --jq .login") printf '%s\n' "${STUB_GH_USER-octocat}" ;;
		*) exit 0 ;;
		esac
	SH

	chmod +x "$FAKEBIN"/*
	PATH="$FAKEBIN:$PATH"
}
