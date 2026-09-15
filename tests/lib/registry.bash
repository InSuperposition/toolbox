# tests/lib/registry.bash — a throwaway local OCI registry + cosign key +
# test artifacts, for any consumer's test suite.
#
# Everything is local and disposable: a `zot` registry on a free port, a
# cosign key pair standing in for openbao://approval-key (the
# TOOLBOX_APPROVE_KEY seam), and tiny `oras push`ed artifacts standing in
# for a built image. No OpenBao, no network, no GHCR — the openbao:// KMS
# leg is proved separately (docs/designs/digest-as-source-of-truth.md
# § Architecture round-trip proof). Loaded through each <tests>/helper.bash,
# after tests/lib/ports.bash (free_port lives there).

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

# start_registry_tls <dir> -> sets REG_TLS (host:port) and TLS_CA
# ($dir's self-signed CA PEM), writes $dir/zot-tls.pid. A separate
# fixture from start_registry (plain HTTP): this repo's `oras` callers
# default to HTTPS with no --plain-http (openbao-verify.sh), so testing
# their real transport needs a TLS listener, not a plain-HTTP one. No
# auth support — bcrypt-hashing a credential needs the external
# `htpasswd` binary, an undeclared system dependency this repo's mise-
# pinned toolchain doesn't have; the auth-failure error path is unit-
# tested directly against real oras output instead (openbao-verify.bats).
start_registry_tls() {
	local dir="$1" port
	port="$(free_port)"
	REG_TLS="127.0.0.1:${port}"
	TLS_CA="$dir/tls-ca.pem"
	openssl req -x509 -newkey rsa:2048 -keyout "$dir/tls-key.pem" -out "$TLS_CA" \
		-days 1 -nodes -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null

	cat >"$dir/zot-tls.json" <<-EOF
		{
		  "distSpecVersion": "1.1.1",
		  "storage": { "rootDirectory": "${dir}/data-tls" },
		  "http": { "address": "127.0.0.1", "port": "${port}",
		            "tls": { "cert": "${TLS_CA}", "key": "${dir}/tls-key.pem" } },
		  "log": { "level": "error" }
		}
	EOF
	zot serve "$dir/zot-tls.json" >"$dir/zot-tls.log" 2>&1 &
	local zpid=$!
	echo "$zpid" >"$dir/zot-tls.pid"
	disown "$zpid" 2>/dev/null || true
	local i=0
	while [ "$i" -lt 50 ]; do
		curl -sfk "https://${REG_TLS}/v2/" >/dev/null 2>&1 && return 0
		sleep 0.1
		i=$((i + 1))
	done
	echo "zot (tls) did not come up on ${REG_TLS}" >&2
	return 1
}

stop_registry_tls() {
	local dir="$1"
	[ -f "$dir/zot-tls.pid" ] && kill "$(cat "$dir/zot-tls.pid")" 2>/dev/null || true
}

# make_key <dir> -> writes $dir/cosign.key + $dir/cosign.pub
make_key() {
	local dir="$1"
	(cd "$dir" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1)
}

# _attach_evidence <dir> <ref> -> attaches a fake CycloneDX SBOM referrer
# and a fake trivy scan-report referrer to <ref>. Shared by make_image and
# make_multiplatform_image — same fake evidence shape, different subject.
_attach_evidence() {
	local dir="$1" ref="$2"
	printf '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[{"name":"remix","version":"3.0.0"}]}' >"$dir/sbom.json"
	printf '{"SchemaVersion":2,"Results":[{"Target":"app","Vulnerabilities":[{"VulnerabilityID":"CVE-2026-1","Severity":"LOW"}]}]}' >"$dir/scan.json"
	(
		cd "$dir" &&
			oras attach --plain-http --artifact-type application/vnd.cyclonedx+json "$ref" "sbom.json:application/vnd.cyclonedx+json" >/dev/null &&
			oras attach --plain-http --artifact-type application/vnd.trivy.report+json "$ref" "scan.json:application/vnd.trivy.report+json" >/dev/null
	)
}

# make_image <dir> -> echoes "<REG>/img@sha256:<digest>", with a fake
# CycloneDX SBOM referrer and a fake trivy scan-report referrer attached.
make_image() {
	local dir="$1" digest
	echo "test image $(date +%s%N)" >"$dir/layer.bin"
	(cd "$dir" && oras push --plain-http "${REG}/img:build" "layer.bin:application/octet-stream" >/dev/null)
	digest="$(oras resolve --plain-http "${REG}/img:build")"
	local ref="${REG}/img@${digest}"
	_attach_evidence "$dir" "$ref"
	echo "$ref"
}

# make_multiplatform_image <dir> -> echoes "<REG>/mimg@sha256:<INDEX-digest>",
# a genuine OCI index (one linux/arm64 child, matching BuildKit's real
# shape closely enough for `oras resolve --platform` to work — verified
# live: a bare `oras push` artifact has no image config and --platform
# errors "unknown config ... expect application/vnd.oci.image.config.v1+json";
# an INDEX with a platform-annotated descriptor resolves correctly even
# when the child itself is a plain artifact, since oras reads the
# platform off the descriptor, not the child's own config). Evidence is
# attached to the INDEX digest (matching scan-attach.yaml's real
# addressing — TODOS.md "Run-scoped build digest identity"), never the
# child — this is what makes the index provably run-unique in production
# and is exactly the shape attestation-sign.sh's new platform-resolution
# step must be tested against.
make_multiplatform_image() {
	local dir="$1" child_digest child_size index_digest
	echo "multiplatform child $(date +%s%N)" >"$dir/mchild.bin"
	(cd "$dir" && oras push --plain-http "${REG}/mimg:child" "mchild.bin:application/octet-stream" >/dev/null)
	child_digest="$(oras resolve --plain-http "${REG}/mimg:child")"
	child_size="$(oras manifest fetch --plain-http "${REG}/mimg:child" | wc -c | tr -d ' ')"

	jq -n --arg d "$child_digest" --argjson s "$child_size" \
		'{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json",
		  manifests: [{mediaType: "application/vnd.oci.image.manifest.v1+json",
		               digest: $d, size: $s,
		               platform: {architecture: "arm64", os: "linux"}}]}' \
		>"$dir/mindex.json"
	(cd "$dir" && oras manifest push --plain-http "${REG}/mimg:multi" mindex.json >/dev/null)
	index_digest="$(oras resolve --plain-http "${REG}/mimg:multi")"
	local ref="${REG}/mimg@${index_digest}"
	_attach_evidence "$dir" "$ref"
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

# make_bare_multiplatform_image <dir> -> the make_multiplatform_image shape
# (a real INDEX, so `oras resolve --platform` still succeeds) with NO
# evidence referrers attached — for exercising the "evidence missing"
# path without also tripping platform-resolution.
make_bare_multiplatform_image() {
	local dir="$1" child_digest child_size index_digest
	echo "bare multiplatform child $(date +%s%N)" >"$dir/bmchild.bin"
	(cd "$dir" && oras push --plain-http "${REG}/bmimg:child" "bmchild.bin:application/octet-stream" >/dev/null)
	child_digest="$(oras resolve --plain-http "${REG}/bmimg:child")"
	child_size="$(oras manifest fetch --plain-http "${REG}/bmimg:child" | wc -c | tr -d ' ')"

	jq -n --arg d "$child_digest" --argjson s "$child_size" \
		'{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json",
		  manifests: [{mediaType: "application/vnd.oci.image.manifest.v1+json",
		               digest: $d, size: $s,
		               platform: {architecture: "arm64", os: "linux"}}]}' \
		>"$dir/bmindex.json"
	(cd "$dir" && oras manifest push --plain-http "${REG}/bmimg:multi" bmindex.json >/dev/null)
	index_digest="$(oras resolve --plain-http "${REG}/bmimg:multi")"
	echo "${REG}/bmimg@${index_digest}"
}
