# deploy/frontend test fixtures. The concern-agnostic half (throwaway zot
# registry, cosign key, fake image artifacts, scratch-dir copy) lives in
# tests/lib/ and is loaded below; what stays here is frontend-specific: the
# docker serving-image path (T5b), the approve.sh call wrappers, and the
# scratch deploy/frontend tree with its own pitchfork.toml.

# --- load the shared test lib (per-dir loader, no BATS_LIB_PATH / mise env) -
# ports.bash first — registry.bash uses free_port.
_d="$BATS_TEST_DIRNAME"
while [ "$_d" != "/" ] && [ ! -e "$_d/mise.toml" ]; do _d="$(dirname "$_d")"; done
# shellcheck source=/dev/null
. "$_d/tests/lib/ports.bash"
# shellcheck source=/dev/null
. "$_d/tests/lib/scratch.bash"
# shellcheck source=/dev/null
. "$_d/tests/lib/registry.bash"
unset _d

# --- approve.sh call wrappers --------------------------------------------

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

# --- deploy.bats (T5b) docker-backed fixture ----------------------------
# A real serving image needs docker + a registry docker can push to. zot
# rejects docker-built manifests, so this uses `registry:3` (pulled once).
# All of this is skipped when docker is unavailable.

deploy_docker_available() { command -v docker >/dev/null && docker info >/dev/null 2>&1; }

# start_docker_registry <dir> -> sets DREG (host:port); writes $dir/dreg.cid
start_docker_registry() {
	local dir="$1" port
	port="$(free_port)"
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
# pitchfork commands never touch a real `frontend` daemon. The per-run
# isolation seams (set by frontend_isolation in setup) are baked into the
# daemon's env block so a pitchfork-restarted run.sh picks them up — a
# `pitchfork restart` does NOT inherit the caller's environment.
scratch_frontend() {
	local s="$1"
	local host_port="${TOOLBOX_FRONTEND_HOST_PORT:-44100}"
	local container="${TOOLBOX_FRONTEND_CONTAINER:-toolbox-frontend}"
	scratch_copy "$s" "deploy/frontend"
	rm -rf "$s/deploy/frontend/scripts/tests" "$s/deploy/frontend/current-image.txt"
	cat >"$s/pitchfork.toml" <<-EOF
		[daemons.frontend]
		run = "./run.sh"
		dir = "deploy/frontend"
		retry = 0
		ready_port = ${host_port}
		env = { TOOLBOX_FRONTEND_HOST_PORT = "${host_port}", TOOLBOX_FRONTEND_CONTAINER = "${container}" }
	EOF
}
