#!/usr/bin/env bats

# environments/local/scripts/tekton-install.sh — the interim Tekton controller
# installer. It MUST verify the pinned SHA-256 before `kubectl apply` and MUST
# refuse on a mismatch (ADR 0001 — the checksum is the trust boundary). Fake
# `curl` + `kubectl` on PATH cover the verify/refuse decision without a
# network or a cluster; the real apply rides with `mise run local:tekton:install`
# against orb k8s (README § Tekton).

setup() {
	load helper
	SW="$(toolbox_repo_root)/environments/local/scripts/tekton-install.sh"

	FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$FAKEBIN"

	# curl stub: writes a fixed body to the -o path; STUB_CURL_RC forces a failure.
	BODY="fake-tekton-release-manifest"
	cat >"$FAKEBIN/curl" <<-SH
		#!/usr/bin/env bash
		rc="\${STUB_CURL_RC:-0}"
		out=""
		while [ \$# -gt 0 ]; do
		  case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac
		done
		if [ "\$rc" -eq 0 ] && [ -n "\$out" ]; then printf '%s' "$BODY" >"\$out"; fi
		exit "\$rc"
	SH

	# kubectl stub: record every invocation.
	KLOG="$BATS_TEST_TMPDIR/kubectl.log"
	cat >"$FAKEBIN/kubectl" <<-SH
		#!/usr/bin/env bash
		echo "\$*" >>"$KLOG"
		exit 0
	SH

	chmod +x "$FAKEBIN"/curl "$FAKEBIN"/kubectl
	PATH="$FAKEBIN:$PATH"

	# a lock whose sha256 matches BODY
	LOCK="$BATS_TEST_TMPDIR/release.lock"
	printf 'version=v1.6.0\nsha256=%s\n' \
		"$(printf '%s' "$BODY" | shasum -a 256 | awk '{print $1}')" >"$LOCK"

	export TOOLBOX_TEKTON_LOCK="$LOCK"
	export TOOLBOX_TEKTON_KUBE_CONTEXT="testctx"
}

@test "checksum matches -> applies the verified local file to the pinned context, never the URL" {
	run "$SW"
	[ "$status" -eq 0 ]
	[ -f "$KLOG" ]
	grep -q -- '--context testctx apply --server-side -f ' "$KLOG"
	# the -f argument is a local path, not an http(s) URL
	run grep -q -- '-f http' "$KLOG"
	[ "$status" -ne 0 ]
}

@test "checksum mismatch -> exit 1 and nothing is applied" {
	sed -i.bak 's/^sha256=.*/sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$LOCK"
	run "$SW"
	[ "$status" -eq 1 ]
	[[ "$output" == *"checksum mismatch"* ]]
	[ ! -f "$KLOG" ]
}

@test "missing lock file -> exit 1" {
	export TOOLBOX_TEKTON_LOCK="$BATS_TEST_TMPDIR/does-not-exist.lock"
	run "$SW"
	[ "$status" -eq 1 ]
	[[ "$output" == *"lock file not found"* ]]
	[ ! -f "$KLOG" ]
}

@test "malformed sha256 in the lock -> exit 1" {
	sed -i.bak 's/^sha256=.*/sha256=not-a-real-digest/' "$LOCK"
	run "$SW"
	[ "$status" -eq 1 ]
	[[ "$output" == *"not 64 lowercase hex"* ]]
	[ ! -f "$KLOG" ]
}

@test "download failure -> exit 1 and nothing is applied" {
	STUB_CURL_RC=22 run "$SW"
	[ "$status" -eq 1 ]
	[[ "$output" == *"download failed"* ]]
	[ ! -f "$KLOG" ]
}
