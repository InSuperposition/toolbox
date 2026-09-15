#!/usr/bin/env bash
set -euo pipefail

# openbao-verify.sh — the hk `openbao-verify` gate for the
# in-cluster OpenBao Helm release (environments/local/openbao/).
#
# The OpenTofu helm provider cannot pin an OCI chart by digest
# (hashicorp/terraform-provider-helm#1596), so this is where the digest
# actually gets enforced:
#
#   1. `oras resolve <repo>/<name>:<chart_version>` == openbao.lock's
#      chart_digest — fail closed. (The bootstrap bridge,
#      re-runs this same assertion immediately before `tofu apply`.)
#   2. `oras resolve <image_ref>:<image_tag>` == the lock's image_digest.
#   3. `helm template` the chart BY DIGEST (`oci://…@<chart_digest>`) with
#      the same value toggles main.tf sets and the committed
#      templates/openbao.hcl.tftpl, then assert the rendered shape:
#      exactly 1 replica, a StatefulSet, an HTTPS listener, a `seal "static"`
#      stanza, the seal + TLS mounts, and NO pod anti-affinity / PDB.
#
# hk runs this as the `openbao-verify` step (check layer). It needs
# network (oras + helm pull) — same class as the bats OpenBao suites.
# Offline / registry-down: prints a skip line and exits 0, like the [k8s]
# gates, so a flapping registry.opentofu.org does not red the whole check.
#
# Test seams (bats): TOOLBOX_OPENBAO_LOCK overrides the lock path;
# TOOLBOX_ORAS_CACERT points both oras calls at a local test registry's CA
# (--ca-file) instead of the system trust store real GHCR/quay use. Unset
# in production.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$(cd "$SCRIPT_DIR/../openbao" && pwd)"
LOCK="${TOOLBOX_OPENBAO_LOCK:-$UNIT_DIR/openbao.lock}"
TFTPL="$UNIT_DIR/templates/openbao.hcl.tftpl"

die() {
	echo "openbao-verify: $*" >&2
	exit 1
}
skip() {
	echo "openbao-verify: $* — skipping (network gate)"
	exit 0
}
val() { sed -n "s/^$1=//p" "$LOCK"; }

# classify_failure <stderr text> — true (0) for a permanent/config-shaped
# failure (auth, TLS cert, malformed ref, a real render error, ...) that
# should fail this gate CLOSED; false (1) for transient network
# unreachability or a not-found (registry down, DNS, or a real
# not-found — the already-shipped skip behavior, not re-litigated here).
# Patterns are the real error text oras 1.3.4 / helm emit for each class
# (live-verified against a local zot fixture, not assumed): connection
# refused and DNS failure both contain "dial tcp"; a timeout contains
# "i/o timeout" or "context deadline exceeded"; a real not-found says
# "... not found" (some registries say "manifest unknown" instead).
# Everything else — "invalid reference" (malformed ref), "x509:
# certificate signed by unknown authority" (cert failure), "basic
# credential not found" (auth failure) — falls to the default: die.
# ": not found" (colon-space, matching the real "<ref>: not found" shape),
# not the bare phrase — "basic credential not found" (auth failure) has
# no colon before it and must NOT collide with the not-found bucket.
classify_failure() {
	case "$1" in
	*'dial tcp'* | *'i/o timeout'* | *'context deadline exceeded'* | \
		*'no such host'* | *'connection refused'* | \
		*'manifest unknown'* | *' 404 '* | *': not found'*)
		return 1 ;;
	*)
		return 0 ;;
	esac
}

# ORAS_CACERT — the --ca-file flag for both oras calls below, only when
# TOOLBOX_ORAS_CACERT is set (bats). Empty in production: real
# GHCR/quay use the system trust store, no flag needed.
ORAS_CACERT=()
[ -n "${TOOLBOX_ORAS_CACERT:-}" ] && ORAS_CACERT=(--ca-file "$TOOLBOX_ORAS_CACERT")

# --- 0. anti-rotation guard FIRST — before every other check in this
#        script, lock/tftpl existence included: a pure local `*.tf` grep,
#        zero dependency on anything else here. It used to run LAST and
#        could be silently skipped by an earlier registry-down exit (or,
#        in principle, any other precondition failing first) — this unit
#        must NEVER tofu-manage the transit mount or approval-key; both
#        are created by the snapshot restore, and a tofu recreate = a key
#        rotation = every past approval attestation stops verifying,
#        plan § B3. Matches an actual resource block / `name =
#        "approval-key"` arg, not the validation string or a comment.
if grep -REn 'resource[[:space:]]+"vault_mount"|name[[:space:]]*=[[:space:]]*"approval-key"' "$UNIT_DIR"/*.tf; then
	die "environments/local/openbao/*.tf tofu-manages the transit mount or approval-key — those are restore-managed, tofu must not touch them"
fi

command -v oras >/dev/null || die "oras not on PATH"
command -v helm >/dev/null || die "helm not on PATH"
[ -f "$LOCK" ] || die "lock file not found: $LOCK"
[ -f "$TFTPL" ] || die "config template not found: $TFTPL"

chart_repo="$(val chart_repository)"
chart_name="$(val chart_name)"
chart_version="$(val chart_version)"
chart_digest="$(val chart_digest)"
image_ref="$(val image_ref)"
image_tag="$(val image_tag)"
image_digest="$(val image_digest)"
seal_key_id="$(val static_seal_key_id)"

{ [ -n "$chart_repo" ] && [ -n "$chart_name" ] && [ -n "$chart_version" ] &&
	[ -n "$chart_digest" ] && [ -n "$image_ref" ] && [ -n "$image_tag" ] &&
	[ -n "$image_digest" ] && [ -n "$seal_key_id" ]; } || die "lock file $LOCK is missing a field"
case "$chart_digest" in sha256:*) ;; *) die "chart_digest is not sha256:<hex>: '$chart_digest'" ;; esac
case "$image_digest" in sha256:*) ;; *) die "image_digest is not sha256:<hex>: '$image_digest'" ;; esac

# oras wants a bare ref (no oci:// scheme).
chart_ref_bare="${chart_repo#oci://}/$chart_name"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# --- 1. chart tag resolves to the locked digest -------------------------
echo "openbao-verify: oras resolve $chart_ref_bare:$chart_version"
got_chart="$(oras resolve "${ORAS_CACERT[@]}" "$chart_ref_bare:$chart_version" 2>"$workdir/oras-chart.err")" || {
	err="$(cat "$workdir/oras-chart.err")"
	if classify_failure "$err"; then
		die "oras resolve failed for $chart_ref_bare:$chart_version (not a network issue): $err"
	fi
	skip "cannot reach $chart_ref_bare (registry down / offline)"
}
[ "$got_chart" = "$chart_digest" ] ||
	die "chart tag $chart_version resolves to $got_chart, lock says $chart_digest — a mutated upstream tag or a stale lock"

# --- 2. image tag resolves to the locked digest ------------------------
echo "openbao-verify: oras resolve $image_ref:$image_tag"
got_image="$(oras resolve "${ORAS_CACERT[@]}" "$image_ref:$image_tag" 2>"$workdir/oras-image.err")" || {
	err="$(cat "$workdir/oras-image.err")"
	if classify_failure "$err"; then
		die "oras resolve failed for $image_ref:$image_tag (not a network issue): $err"
	fi
	skip "cannot reach $image_ref (registry down / offline)"
}
[ "$got_image" = "$image_digest" ] ||
	die "image tag $image_tag resolves to $got_image, lock says $image_digest"

# --- 3. render the chart BY DIGEST and assert the shape ----------------
values="$workdir/values.yaml"
{
	echo 'global:'
	echo '  tlsDisable: false'
	echo 'server:'
	echo '  affinity: ""'
	echo '  ha:'
	echo '    enabled: true'
	echo '    replicas: 1'
	echo '    raft:'
	echo '      enabled: true'
	echo '      setNodeId: true'
	echo '      config: |'
	# The security-critical stanza comes from the COMMITTED template, not a
	# copy — zero drift with what tofu applies. The template's one
	# interpolation (${static_seal_key_id}) is substituted with the pinned
	# id from the lock so the rendered config matches tofu's.
	sed -e "s/\${static_seal_key_id}/$seal_key_id/g" -e 's/^/        /' "$TFTPL"
	echo '    disruptionBudget:'
	echo '      enabled: false'
	echo '  dataStorage:'
	echo '    enabled: true'
	# Secret NAMES are irrelevant to the structural asserts (nothing here
	# talks to a cluster) — the mount paths are what must be right.
	echo '  volumes:'
	echo '    - name: seal'
	echo '      secret: { secretName: openbao-seal }'
	echo '    - name: tls'
	echo '      secret: { secretName: openbao-tls }'
	echo '  volumeMounts:'
	echo '    - { name: seal, mountPath: /openbao/seal, readOnly: true }'
	echo '    - { name: tls, mountPath: /openbao/tls, readOnly: true }'
	echo 'injector:'
	echo '  enabled: false'
	echo 'csi:'
	echo '  enabled: false'
} >"$values"

rendered="$workdir/rendered.yaml"
helm template openbao "oci://$chart_ref_bare@$chart_digest" -f "$values" >"$rendered" 2>"$workdir/helm.err" || {
	err="$(cat "$workdir/helm.err")"
	if classify_failure "$err"; then
		die "helm template failed (not a network issue): $err"
	fi
	skip "helm template failed (offline / registry): $(tail -1 "$workdir/helm.err")"
}

fail=0
check() {
	if eval "$2"; then
		echo "  ok   $1"
	else
		echo "  FAIL $1" >&2
		fail=1
	fi
}

check "exactly one replica" \
	"[ \"\$(grep -cE '^  replicas: 1\$' '$rendered')\" = 1 ]"
check "a StatefulSet (not a Deployment)" \
	"grep -qxE 'kind: StatefulSet' '$rendered' && ! grep -qxE 'kind: Deployment' '$rendered'"
check "no pod anti-affinity" \
	"! grep -qE 'podAntiAffinity' '$rendered'"
check "no PodDisruptionBudget" \
	"! grep -qE 'kind: PodDisruptionBudget' '$rendered'"
check "HTTPS listener — https port name + listener tls_disable=false" \
	"grep -qE 'name: https\$' '$rendered' && grep -qE '^[[:space:]]+tls_disable[[:space:]]*=[[:space:]]*false\b' '$rendered' && ! grep -qE '^[[:space:]]+tls_disable[[:space:]]*=[[:space:]]*(true|1)\b' '$rendered'"
check "seal \"static\" stanza with the shared key id" \
	"grep -qE 'seal \"static\"' '$rendered' && grep -qF 'current_key_id = \"$seal_key_id\"' '$rendered'"
check "raft storage" \
	"grep -qE 'storage \"raft\"' '$rendered'"
check "seal Secret mounted at /openbao/seal" \
	"grep -qE 'mountPath: /openbao/seal' '$rendered'"
check "TLS Secret mounted at /openbao/tls" \
	"grep -qE 'mountPath: /openbao/tls' '$rendered'"

[ "$fail" = 0 ] || die "rendered chart does not match the expected shape"

echo "openbao-verify: OK — chart $chart_version @ $chart_digest, image @ $image_digest; no approval-key / vault_mount in the unit"
