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
# a literal deploy/ path. `crane copy` is idempotent (skips manifests already
# present) and digest-preserving (the seeded manifest keeps its sha256, so the
# Dockerfile's `@sha256:` pins still resolve through the mirror).
#
# Path mapping — the zot repo path is what BuildKit's mirror will request:
#   node:26-slim@sha256          -> docker.io/library/node        -> <zot>/library/node:26-slim
#   docker/dockerfile:1@sha256   -> docker.io/docker/dockerfile   -> <zot>/docker/dockerfile:1
#   gcr.io/distroless/x:t@sha256 -> gcr.io/distroless/x           -> <zot>/distroless/x:t
#
# Exit: 0 ok · 2 bad args · 3 no digest-pinned image found · 4 a copy failed.

DOCKERFILE="${1:-}"
ZOT="${2:-localhost:30500}"

[ -n "$DOCKERFILE" ] || { echo "usage: registry-seed.sh <dockerfile> [zot-registry]" >&2; exit 2; }
[ -f "$DOCKERFILE" ] || { echo "registry-seed: no such file: $DOCKERFILE" >&2; exit 2; }
command -v crane >/dev/null || { echo "registry-seed: crane not on PATH — run \`mise install\`" >&2; exit 2; }

# Every `<ref>@sha256:<64 hex>` on a `# syntax=` or `FROM` line.
mapfile -t refs < <(
	grep -oE '^(# syntax=|FROM[[:space:]]+)[^[:space:]]+@sha256:[0-9a-f]{64}' "$DOCKERFILE" \
		| sed -E 's/^# syntax=//; s/^FROM[[:space:]]+//'
)
[ "${#refs[@]}" -gt 0 ] || { echo "registry-seed: no digest-pinned images in $DOCKERFILE" >&2; exit 3; }

# src_to_zot_dst <ref@sha256:...> -> "<zot>/<repo-path>:<tag>"
# (drops the digest — crane copy carries it; keeps the tag as the mirror key)
src_to_zot_dst() {
	local ref="${1%@sha256:*}" repo="" tag="latest"
	case "$ref" in
	*:*) tag="${ref##*:}"; ref="${ref%:*}" ;;
	esac
	# The first path segment is a registry host IFF it has a '.' or ':' —
	# strip it; otherwise the whole ref is a docker.io repo path.
	case "$ref" in
	*/*)
		case "${ref%%/*}" in
		*.* | *:*) repo="${ref#*/}" ;;                 # gcr.io/distroless/x -> distroless/x
		*) repo="$ref" ;;                              # docker/dockerfile (docker.io, 2-segment)
		esac
		;;
	*) repo="library/$ref" ;;                          # node -> library/node (docker.io official)
	esac
	printf '%s/%s:%s\n' "$ZOT" "$repo" "$tag"
}

rc=0
for src in "${refs[@]}"; do
	dst="$(src_to_zot_dst "$src")"
	echo "==> seed  $src"
	echo "     ->  $dst"
	if ! crane copy "$src" "$dst" --insecure; then
		echo "registry-seed: copy failed: $src -> $dst" >&2
		rc=4
	fi
done
[ "$rc" -eq 0 ] && echo "registry-seed: ${#refs[@]} image(s) present in $ZOT"
exit "$rc"
