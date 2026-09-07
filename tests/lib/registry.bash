# tests/lib/registry.bash — a throwaway local OCI registry + cosign key +
# test artifacts, for any consumer's test suite.
#
# Everything is local and disposable: a `zot` registry on a free port, a
# cosign key pair standing in for openbao://approval-key (the
# TOOLBOX_APPROVE_KEY seam), and tiny `oras push`ed artifacts standing in
# for a built image. No OpenBao, no network, no GHCR — the openbao:// KMS
# leg is proved separately (docs/designs/digest-as-source-of-truth.md
# § Architecture round-trip proof). Loaded through each <tests>/helper.bash.

# free_port — ask the OS for an unused loopback port.
free_port() {
	python3 - <<-'PY'
		import socket
		s = socket.socket()
		s.bind(("127.0.0.1", 0))
		print(s.getsockname()[1])
		s.close()
	PY
}

# start_registry <dir> -> sets REG (host:port), writes $dir/zot.pid
start_registry() {
	local dir="$1" port
	port="$(free_port)"
	REG="127.0.0.1:${port}"
	cat >"$dir/zot.json" <<-EOF
		{
		  "distSpecVersion": "1.1.1",
		  "storage": { "rootDirectory": "${dir}/data" },
		  "http": { "address": "127.0.0.1", "port": "${port}" },
		  "log": { "level": "error" }
		}
	EOF
	# disown so bats killing the setup_file subshell does not take zot with
	# it (background jobs started in setup_file are otherwise SIGHUP'd when
	# it returns).
	zot serve "$dir/zot.json" >"$dir/zot.log" 2>&1 &
	local zpid=$!
	echo "$zpid" >"$dir/zot.pid"
	disown "$zpid" 2>/dev/null || true
	local i=0
	while [ "$i" -lt 50 ]; do
		curl -sf "http://${REG}/v2/" >/dev/null 2>&1 && return 0
		sleep 0.1
		i=$((i + 1))
	done
	echo "zot did not come up on ${REG}" >&2
	return 1
}

stop_registry() {
	local dir="$1"
	[ -f "$dir/zot.pid" ] && kill "$(cat "$dir/zot.pid")" 2>/dev/null || true
}

# make_key <dir> -> writes $dir/cosign.key + $dir/cosign.pub
make_key() {
	local dir="$1"
	(cd "$dir" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1)
}

# make_image <dir> -> echoes "<REG>/img@sha256:<digest>", with a fake
# CycloneDX SBOM referrer and a fake trivy scan-report referrer attached.
make_image() {
	local dir="$1" digest
	echo "test image $(date +%s%N)" >"$dir/layer.bin"
	(cd "$dir" && oras push --plain-http "${REG}/img:build" "layer.bin:application/octet-stream" >/dev/null)
	digest="$(oras resolve --plain-http "${REG}/img:build")"
	local ref="${REG}/img@${digest}"

	printf '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[{"name":"remix","version":"3.0.0"}]}' >"$dir/sbom.json"
	printf '{"SchemaVersion":2,"Results":[{"Target":"app","Vulnerabilities":[{"VulnerabilityID":"CVE-2026-1","Severity":"LOW"}]}]}' >"$dir/scan.json"
	(
		cd "$dir" &&
			oras attach --plain-http --artifact-type application/vnd.cyclonedx+json "$ref" "sbom.json:application/vnd.cyclonedx+json" >/dev/null &&
			oras attach --plain-http --artifact-type application/vnd.trivy.report+json "$ref" "scan.json:application/vnd.trivy.report+json" >/dev/null
	)
	echo "$ref"
}

# make_bare_image <dir> -> an image ref with NO referrers attached
make_bare_image() {
	local dir="$1" digest
	echo "bare image $(date +%s%N)" >"$dir/bare.bin"
	(cd "$dir" && oras push --plain-http "${REG}/bare:build" "bare.bin:application/octet-stream" >/dev/null)
	digest="$(oras resolve --plain-http "${REG}/bare:build")"
	echo "${REG}/bare@${digest}"
}
