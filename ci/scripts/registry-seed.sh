#!/usr/bin/env bash
set -euo pipefail

# ci/scripts/registry-seed.sh <dockerfile> [zot-registry]
#
# Copy every digest-pinned image referenced by <dockerfile> — the `# syntax=`
# frontend and each `FROM <ref>@sha256:<digest>` — into a local zot, so an
# in-cluster BuildKit build never has to reach docker.io / gcr.io.
#
# Why (TODOS.md T7b1-followup, /investigate 2026-09-08): this OrbStack cluster
# hands pods a working AF_INET6 stack + AAAA DNS but no routable IPv6 egress,
# so Go registry clients (buildkit/containerd, and zot's own regclient) can
# pick an unreachable AAAA and hard-fail ~50% of external image fetches. This
# script runs on the HOST, where IPv4 works, and seeds the images once; the
# build Task's buildkitd.toml then mirrors docker.io + gcr.io to zot.
#
# Consumer-agnostic (rules/boundary-ci.yml): <dockerfile> is an argument, never
# a literal deploy/ path. `oras cp` is idempotent (skips manifests already
# present) and digest-preserving (the seeded manifest keeps its sha256, so the
# Dockerfile's `@sha256:` pins still resolve through the mirror; live-verified
# against this script's own three real pins). `--to-ca-file "$ZOT_CA"` trusts
# zot's HTTPS listener (T7c R1b-ii-c) — `$ZOT_CA` defaults to the SAME file
# `mise run local:zot:trust` (T7c R1b-ii-b) already writes for the node
# dockerd, no second fetch. Not `crane`: `crane` has no CA-file override at
# all on this darwin/Go toolchain (only a global `--insecure`); `oras`'s
# `--to-ca-file`/`--from-ca-file` are independently scoped per endpoint
# (confirmed from `oras-project/oras` source), so the public docker.io/gcr.io
# source keeps ordinary system trust while only the zot destination gets the
# dev CA.
#
# One real behavior gap `crane` papered over: unlike `crane`/`docker pull`,
# `oras` has NO implicit docker.io default for a bare or 2-segment ref —
# `qualify_docker_io` below makes that explicit before the ref ever reaches
# `oras cp` (live-caught: a bare "node:tag@sha256" errored "missing registry
# or repository"; "docker/dockerfile:1@sha256" resolved oras to a literal,
# nonexistent host "docker").
#
# Path mapping — the zot repo path is what BuildKit's mirror will request:
#   node:26-slim@sha256          -> docker.io/library/node        -> <zot>/library/node:26-slim
#   docker/dockerfile:1@sha256   -> docker.io/docker/dockerfile   -> <zot>/docker/dockerfile:1
#   gcr.io/distroless/x:t@sha256 -> gcr.io/distroless/x           -> <zot>/distroless/x:t
#
# Exit: 0 ok · 2 bad args · 3 no digest-pinned image found · 4 a copy failed.

DOCKERFILE="${1:-}"
ZOT="${2:-zot.zot.svc.cluster.local:5000}"
ZOT_CA="${TOOLBOX_ZOT_CA:-$HOME/.docker/certs.d/zot.zot.svc.cluster.local:5000/ca.crt}"

[ -n "$DOCKERFILE" ] || { echo "usage: registry-seed.sh <dockerfile> [zot-registry]" >&2; exit 2; }
[ -f "$DOCKERFILE" ] || { echo "registry-seed: no such file: $DOCKERFILE" >&2; exit 2; }
command -v oras >/dev/null || { echo "registry-seed: oras not on PATH — run \`mise install\`" >&2; exit 2; }
[ -f "$ZOT_CA" ] || { echo "registry-seed: $ZOT_CA not found — run \`mise run local:zot:trust\` first" >&2; exit 2; }

# Every `<ref>@sha256:<64 hex>` on a `# syntax=` or `FROM` line.
mapfile -t refs < <(
	grep -oE '^(# syntax=|FROM[[:space:]]+)[^[:space:]]+@sha256:[0-9a-f]{64}' "$DOCKERFILE" \
		| sed -E 's/^# syntax=//; s/^FROM[[:space:]]+//'
)
[ "${#refs[@]}" -gt 0 ] || { echo "registry-seed: no digest-pinned images in $DOCKERFILE" >&2; exit 3; }

# split_ref <ref[:tag]@sha256:...> -> sets $_repo (registry-host-stripped)
# and $_tag. Shared by qualify_docker_io and src_to_zot_dst so the "is this
# already host-qualified" call is made exactly once, the same way, for both
# the source ref oras actually fetches and the destination path it writes.
split_ref() {
	local ref="${1%@sha256:*}"
	_tag="latest"
	case "$ref" in
	*:*) _tag="${ref##*:}"; ref="${ref%:*}" ;;
	esac
	# The first path segment is a registry host IFF it has a '.' or ':' —
	# strip it; otherwise the whole ref is a docker.io repo path.
	case "$ref" in
	*/*)
		case "${ref%%/*}" in
		*.* | *:*) _repo="${ref#*/}" ;;                 # gcr.io/distroless/x -> distroless/x
		*) _repo="$ref" ;;                              # docker/dockerfile (docker.io, 2-segment)
		esac
		;;
	*) _repo="library/$ref" ;;                          # node -> library/node (docker.io official)
	esac
}

# qualify_docker_io <ref@sha256:...> -> a fully host-qualified ref oras can
# resolve. `crane` (this script's predecessor, see git history) defaulted a
# bare/2-segment ref to docker.io the way `docker pull` does; `oras` does
# NOT — it takes the literal first path segment as the registry host with no
# implicit default (confirmed live: "docker/dockerfile:1@..." resolved oras
# to host "docker", and a bare "node:tag@..." errored "missing registry or
# repository"). A ref that already names a real host (gcr.io/...) passes
# through unchanged; only the docker.io-implicit forms get qualified.
qualify_docker_io() {
	local ref="${1%@sha256:*}" digest="${1#*@}"
	case "$ref" in
	*/*)
		case "${ref%%/*}" in
		*.* | *:*) printf '%s\n' "$1"; return ;;        # already host-qualified
		esac
		;;
	esac
	split_ref "$1"
	printf 'docker.io/%s:%s@%s\n' "$_repo" "$_tag" "$digest"
}

# src_to_zot_dst <ref@sha256:...> -> "<zot>/<repo-path>:<tag>"
# (drops the digest — oras cp carries it; keeps the tag as the mirror key)
src_to_zot_dst() {
	split_ref "$1"
	printf '%s/%s:%s\n' "$ZOT" "$_repo" "$_tag"
}

rc=0
for src in "${refs[@]}"; do
	fq_src="$(qualify_docker_io "$src")"
	dst="$(src_to_zot_dst "$src")"
	echo "==> seed  $src"
	echo "     ->  $dst"
	if ! oras cp "$fq_src" "$dst" --to-ca-file "$ZOT_CA"; then
		echo "registry-seed: copy failed: $src -> $dst" >&2
		rc=4
	fi
done
[ "$rc" -eq 0 ] && echo "registry-seed: ${#refs[@]} image(s) present in $ZOT"
exit "$rc"
