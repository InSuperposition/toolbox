#!/usr/bin/env bats

# environments/local/scripts/zot-trust.sh — the T7c R1b-ii-b host trust
# install. Fakes `kubectl` on PATH (no live cluster in bats) and points
# every real path at scratch so a run never touches this machine's actual
# ~/.docker/certs.d or $XDG_STATE_HOME.

setup() {
	load helper
	SW="$(toolbox_repo_root)/environments/local/scripts/zot-trust.sh"

	SCRATCH="$BATS_TEST_TMPDIR"
	FAKEBIN="$SCRATCH/fakebin"
	mkdir -p "$FAKEBIN"

	export TOOLBOX_ZOT_HOST="zot.example.test:5000"
	export TOOLBOX_ZOT_DOCKER_CERTS_D="$SCRATCH/docker-certs.d"
	export XDG_STATE_HOME="$SCRATCH/state"
	export TOOLBOX_ZOT_SYSTEM_BUNDLE="$SCRATCH/system-cert.pem"

	# A minimal but real self-signed cert (openssl req, no cluster needed) —
	# valid X.509, so the script's own `openssl x509 -noout` check passes.
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
		-keyout "$SCRATCH/dev-ca.key" -out "$SCRATCH/dev-ca.crt" \
		-days 1 -nodes -subj "/CN=toolbox-dev-ca-test" 2>/dev/null

	# A 2-cert "system snapshot" fixture — real PEM blocks, arbitrary CN.
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
		-keyout "$SCRATCH/sys1.key" -out "$SCRATCH/sys1.crt" \
		-days 1 -nodes -subj "/CN=fixture-root-1" 2>/dev/null
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
		-keyout "$SCRATCH/sys2.key" -out "$SCRATCH/sys2.crt" \
		-days 1 -nodes -subj "/CN=fixture-root-2" 2>/dev/null
	cat "$SCRATCH/sys1.crt" "$SCRATCH/sys2.crt" >"$TOOLBOX_ZOT_SYSTEM_BUNDLE"

	_stub_kubectl_ok
	PATH="$FAKEBIN:$PATH"
}

teardown() {
	cd /
}

_stub_kubectl_ok() {
	local b64
	b64="$(base64 <"$SCRATCH/dev-ca.crt" | tr -d '\n')"
	cat >"$FAKEBIN/kubectl" <<-SH
		#!/usr/bin/env bash
		if [[ "\$*" == *"get secret toolbox-dev-ca"* ]]; then
			echo -n '$b64'
			exit 0
		fi
		echo "fake kubectl: unexpected invocation: \$*" >&2
		exit 1
	SH
	chmod +x "$FAKEBIN/kubectl"
}

_stub_kubectl_not_found() {
	cat >"$FAKEBIN/kubectl" <<-SH
		#!/usr/bin/env bash
		echo "Error from server (NotFound)" >&2
		exit 1
	SH
	chmod +x "$FAKEBIN/kubectl"
}

@test "writes both trust files from the live Secret" {
	run "$SW"
	[ "$status" -eq 0 ]
	[ -f "$TOOLBOX_ZOT_DOCKER_CERTS_D/$TOOLBOX_ZOT_HOST/ca.crt" ]
	[ -f "$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt" ]
}

@test "the node dockerd file is exactly the dev CA" {
	"$SW"
	diff "$SCRATCH/dev-ca.crt" "$TOOLBOX_ZOT_DOCKER_CERTS_D/$TOOLBOX_ZOT_HOST/ca.crt"
}

@test "the concat bundle carries system certs + the dev CA (3 total)" {
	"$SW"
	local count
	count="$(grep -c 'BEGIN CERTIFICATE' "$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt")"
	[ "$count" -eq 3 ]
}

@test "the concat bundle's dev CA block matches the source" {
	"$SW"
	# The bundle is system(2) + dev CA(1) appended last — the tail must
	# match the fetched cert byte-for-byte.
	tail -n "$(wc -l <"$SCRATCH/dev-ca.crt")" "$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt" >"$SCRATCH/tail.crt"
	diff "$SCRATCH/dev-ca.crt" "$SCRATCH/tail.crt"
}

@test "idempotent — a second run reproduces byte-identical output" {
	"$SW"
	cp "$TOOLBOX_ZOT_DOCKER_CERTS_D/$TOOLBOX_ZOT_HOST/ca.crt" "$SCRATCH/first-node.crt"
	cp "$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt" "$SCRATCH/first-bundle.crt"
	run "$SW"
	[ "$status" -eq 0 ]
	diff "$SCRATCH/first-node.crt" "$TOOLBOX_ZOT_DOCKER_CERTS_D/$TOOLBOX_ZOT_HOST/ca.crt"
	diff "$SCRATCH/first-bundle.crt" "$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt"
}

@test "clean-fail when the Secret is not found — no files written" {
	_stub_kubectl_not_found
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"toolbox-dev-ca Secret not found"* ]]
	[ ! -e "$TOOLBOX_ZOT_DOCKER_CERTS_D" ]
	[ ! -e "$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt" ]
}

@test "clean-fail on a corrupt (non-X.509) Secret value — no files written" {
	cat >"$FAKEBIN/kubectl" <<-SH
		#!/usr/bin/env bash
		echo -n 'bm90LWEtY2VydA=='  # base64("not-a-cert")
	SH
	chmod +x "$FAKEBIN/kubectl"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"did not parse as a valid X.509 certificate"* ]]
	[ ! -e "$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt" ]
}

@test "clean-fail when the system bundle is missing — no files written" {
	rm -f "$TOOLBOX_ZOT_SYSTEM_BUNDLE"
	run "$SW"
	[ "$status" -ne 0 ]
	[[ "$output" == *"$TOOLBOX_ZOT_SYSTEM_BUNDLE not found"* ]]
	[ ! -e "$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt" ]
}

@test "a failed run does not disturb a prior good bundle" {
	"$SW"
	cp "$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt" "$SCRATCH/good-bundle.crt"
	_stub_kubectl_not_found
	run "$SW"
	[ "$status" -ne 0 ]
	diff "$SCRATCH/good-bundle.crt" "$XDG_STATE_HOME/toolbox/zot/zot-bundle.crt"
}
