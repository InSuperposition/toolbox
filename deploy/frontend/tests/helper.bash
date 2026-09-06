# Shared fixture for approve.bats / verify-approval.bats.
#
# Everything is local and throwaway: a `zot` registry on a free port, a
# cosign key pair standing in for openbao://approval-key (approve.sh's
# TOOLBOX_APPROVE_KEY seam), and a tiny `oras push`ed artifact standing in
# for the built image. No OpenBao, no network, no GHCR — the openbao:// KMS
# leg is proved separately (docs/designs/digest-as-source-of-truth.md § T5
# round-trip proof).

_free_port() {
	# ask the OS for an unused port
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
	port="$(_free_port)"
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
	( cd "$dir" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1 )
}

# make_image <dir> -> echoes "<REG>/img@sha256:<digest>", with a fake
# CycloneDX SBOM referrer and a fake trivy scan-report referrer attached.
make_image() {
	local dir="$1" digest
	echo "test image $(date +%s%N)" >"$dir/layer.bin"
	( cd "$dir" && oras push --plain-http "${REG}/img:build" "layer.bin:application/octet-stream" >/dev/null )
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
	( cd "$dir" && oras push --plain-http "${REG}/bare:build" "bare.bin:application/octet-stream" >/dev/null )
	digest="$(oras resolve --plain-http "${REG}/bare:build")"
	echo "${REG}/bare@${digest}"
}

# run_approve <image-ref> <approve|reject> <reason> -> runs approve.sh with
# the local test key and the decision fed on stdin. Echoes its stdout.
run_approve() {
	printf '%s\n%s\n' "$2" "$3" >"$FIX/answers"
	TOOLBOX_APPROVE_KEY="$FIX/cosign.key" \
	COSIGN_PASSWORD="" \
	TOOLBOX_APPROVED_BY="bats" \
		"$SCRIPTS/approve.sh" "$1" <"$FIX/answers"
}

# attestation_digest <approve output> -> the sha256:... it told the operator to record
attestation_digest() {
	printf '%s' "$1" | sed -n 's/^attestation digest: //p'
}

# --- deploy.bats (T5b) docker-backed fixture -------------------------------
# A real serving image needs docker + a registry docker can push to. zot
# rejects docker-built manifests, so this uses `registry:3` (pulled once).
# All of this is skipped when docker is unavailable.

deploy_docker_available() { command -v docker >/dev/null && docker info >/dev/null 2>&1; }

# start_docker_registry <dir> -> sets DREG (host:port); writes $dir/dreg.cid
start_docker_registry() {
	local dir="$1" port
	port="$(_free_port)"
	DREG="127.0.0.1:${port}"
	docker run -d --rm -p "${port}:5000" --name "toolbox-t5b-reg-${port}" registry:3 >"$dir/dreg.cid" 2>/dev/null
	local i=0
	while [ "$i" -lt 50 ]; do
		curl -sf "http://${DREG}/v2/" >/dev/null 2>&1 && return 0
		sleep 0.1
		i=$((i + 1))
	done
	echo "registry:3 did not come up on ${DREG}" >&2
	return 1
}

stop_docker_registry() {
	local dir="$1"
	[ -f "$dir/dreg.cid" ] && docker rm -f "$(cat "$dir/dreg.cid")" >/dev/null 2>&1 || true
}

# make_serving_image <dir> -> echoes "<DREG>/frontend@sha256:<digest>", a
# distroless image whose CMD serves HTTP 200 on :44100, with SBOM + scan
# referrers attached.
make_serving_image() {
	local dir="$1" digest
	mkdir -p "$dir/img"
	cat >"$dir/img/server.js" <<-'JS'
		require("http").createServer((_q, r) => { r.writeHead(200); r.end("t5b ok\n"); }).listen(process.env.PORT || 44100);
	JS
	cat >"$dir/img/Dockerfile" <<-'DOCKER'
		FROM gcr.io/distroless/nodejs26-debian13:nonroot
		WORKDIR /app
		COPY server.js .
		CMD ["server.js"]
	DOCKER
	docker build --platform linux/arm64 -t "${DREG}/frontend:build" "$dir/img" >/dev/null 2>&1
	docker push "${DREG}/frontend:build" >/dev/null 2>&1
	digest="$(oras resolve --plain-http "${DREG}/frontend:build")"
	local ref="${DREG}/frontend@${digest}"
	printf '{"bomFormat":"CycloneDX","components":[{"name":"node"}]}' >"$dir/img/sbom.json"
	printf '{"SchemaVersion":2,"Results":[]}' >"$dir/img/scan.json"
	(
		cd "$dir/img" &&
			oras attach --plain-http --artifact-type application/vnd.cyclonedx+json "$ref" sbom.json:application/vnd.cyclonedx+json >/dev/null &&
			oras attach --plain-http --artifact-type application/vnd.trivy.report+json "$ref" scan.json:application/vnd.trivy.report+json >/dev/null
	)
	echo "$ref"
}

# sign_local <image-ref> <verdict> -> echoes the attestation digest, signed
# with $FIX/cosign.key (make_key must have run).
sign_local() {
	printf '%s\n%s\n' "$2" "t5b $2" >"$FIX/ans"
	local out
	out="$(TOOLBOX_APPROVE_KEY="$FIX/cosign.key" COSIGN_PASSWORD="" TOOLBOX_APPROVED_BY="bats" \
		"$SCRIPTS/approve.sh" "$1" <"$FIX/ans")"
	attestation_digest "$out"
}

# scratch_frontend <scratchdir> -> copies deploy/frontend into <scratchdir>
# and writes a pitchfork.toml there with only the frontend daemon, so
# pitchfork commands never touch a real `frontend` daemon.
scratch_frontend() {
	local s="$1" repo
	repo="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
	mkdir -p "$s/deploy"
	cp -r "$repo/deploy/frontend" "$s/deploy/frontend"
	rm -rf "$s/deploy/frontend/tests" "$s/deploy/frontend/current-image.txt"
	cat >"$s/pitchfork.toml" <<-EOF
		[daemons.frontend]
		run = "./run.sh"
		dir = "deploy/frontend"
		retry = 0
		ready_port = 44100
	EOF
}
