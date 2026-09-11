# deploy/frontend test fixtures. The concern-agnostic half (throwaway zot
# registry, cosign key, fake image artifacts, scratch-dir copy, free ports)
# lives in tests/lib/ and is loaded below. What stays here is
# frontend-specific: the docker serving-image path, the attestation-sign
# fixture wrapper, and the scratch deploy/frontend + attestation tree with
# its own pitchfork.toml.
#
# The default TOOLBOX_ATTESTATION_VERIFY seam (repo-structure.md § The
# concerns, C4) is exercised by every scratch test: scratch_frontend copies
# BOTH attestation/ and deploy/frontend/ plus a mise.toml marker, and no
# test sets TOOLBOX_ATTESTATION_VERIFY — frontend-serve.sh / frontend-deploy.sh
# resolve the seam to the scratch attestation/ copy on their own.

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
ATTESTATION_SCRIPTS="$_d/attestation/scripts"
unset _d

# --- attestation-sign fixture wrapper ----------------------------------
# deploy/frontend consumes an approved image, so its tests need to produce
# one (an allowed edge: deploy/frontend ▶ attestation). Signs with the
# local test key via the TOOLBOX_APPROVE_KEY seam — no OpenBao.

# sign_image <image-ref> <approve|reject> [reason] -> echoes the attestation
# digest the sign script told the operator to record.
sign_image() {
	local reason="${3:-t5b $2}"
	printf '%s\n%s\n' "$2" "$reason" >"$FIX/sign-answers"
	local out
	out="$(TOOLBOX_APPROVE_KEY="$FIX/cosign.key" COSIGN_PASSWORD="" TOOLBOX_APPROVED_BY="bats" \
		"$ATTESTATION_SCRIPTS/attestation-sign.sh" "$1" <"$FIX/sign-answers")"
	printf '%s' "$out" | sed -n 's/^attestation digest: //p'
}

# --- frontend-deploy.bats docker-backed fixture ----------------------------
# A real serving image needs docker + a registry docker can push to. zot
# rejects docker-built manifests, so this uses `registry:3` (pulled once).
# All of this is skipped when docker is unavailable.

# In CI the [docker] bats cases must RUN, not skip — a green run has to mean
# the heavy matrix executed, not merely got scheduled (T9a). Locally, absent
# docker still skips as before.
deploy_docker_available() {
	if command -v docker >/dev/null && docker info >/dev/null 2>&1; then return 0; fi
	if [ -n "${CI:-}" ]; then
		echo "CI: docker required for [docker] bats cases, not available" >&2
		exit 1
	fi
	return 1
}

# start_docker_registry <dir> -> sets DREG (host:port); writes $dir/dreg.cid
start_docker_registry() {
	local dir="$1" port
	port="$(free_port)"
	DREG="127.0.0.1:${port}"
	docker run -d --rm -p "${port}:5000" --name "toolbox-t5b-reg-${port}" registry:3 >"$dir/dreg.cid"
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
	docker build --platform linux/arm64 -t "${DREG}/frontend:build" "$dir/img" >/dev/null
	docker push "${DREG}/frontend:build" >/dev/null
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

# scratch_frontend <scratchdir> -> a self-contained checkout slice: the
# attestation/ seam + deploy/frontend/ + a mise.toml marker + a pitchfork.toml
# with only the frontend daemon, so pitchfork commands never touch a real
# `frontend` daemon and the default verify seam resolves inside the scratch.
# The per-run isolation seams (set by frontend_isolation in setup) are baked
# into the daemon's env block so a pitchfork-restarted frontend-serve.sh
# picks them up — `pitchfork restart` does NOT inherit the caller's env.
scratch_frontend() {
	local s="$1"
	local host_port="${TOOLBOX_FRONTEND_HOST_PORT:-44100}"
	local container="${TOOLBOX_FRONTEND_CONTAINER:-toolbox-frontend}"
	scratch_copy "$s" "attestation" "deploy/frontend"
	rm -rf "$s/attestation/scripts/tests" \
		"$s/deploy/frontend/scripts/tests" \
		"$s/deploy/frontend/current-image.txt"
	# mise.toml marker — frontend_repo_root (lib/frontend.sh) walks up to it
	# to resolve the default attestation-verify path.
	: >"$s/mise.toml"
	cat >"$s/pitchfork.toml" <<-EOF
		[daemons.frontend]
		run = "./scripts/frontend-serve.sh"
		dir = "deploy/frontend"
		retry = 0
		ready_port = ${host_port}
		env = { TOOLBOX_FRONTEND_HOST_PORT = "${host_port}", TOOLBOX_FRONTEND_CONTAINER = "${container}" }
	EOF
}

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
		h64="$(printf 'a%.0s' {1..64})"
		s64="$(printf 'b%.0s' {1..64})"
		default_discover='{"referrers":[{"artifactType":"application/vnd.trivy.report+json","digest":"sha256:'"$s64"'"}]}'
		case "$*" in
		*discover*) printf '%s' "${STUB_ORAS_DISCOVER:-$default_discover}"; exit 0 ;;
		*resolve*)  printf '%s\n' "${STUB_DIGEST:-sha256:$h64}"; exit 0 ;;
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
