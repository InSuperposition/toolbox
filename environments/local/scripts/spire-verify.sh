#!/usr/bin/env bash
set -euo pipefail

# spire-verify.sh — the hk `spire-verify` gate for the in-cluster SPIRE
# Server + Agent Helm release (environments/local/spire/).
#
# Unlike OpenBao's OCI chart repo, `https://spiffe.github.io/helm-charts-hardened/`
# is a CLASSIC (non-OCI) Helm repo — there is no `oras resolve` digest
# lookup. This is where the digest actually gets enforced instead:
#
#   1. `helm pull <chart> --repo <repo> --version <pinned>` then
#      `sha256sum` the downloaded `.tgz` == spire.lock's digest — fail
#      closed. (The bootstrap bridge re-runs this same assertion
#      immediately before `tofu apply`.)
#   2. `helm template` BOTH pulled (already digest-verified) `.tgz`s with
#      the same value toggles main.tf sets, then assert the rendered
#      shape: spire-crds' CRDs exist, spire-server is a StatefulSet with
#      the overridden ServiceAccount name and the vault upstreamAuthority
#      plugin wired to OpenBao's `pki` mount and its kubernetes-auth role,
#      spire-agent is a DaemonSet, the k8sPSAT TokenReview ClusterRole
#      exists, and the controller-manager's default ClusterSPIFFEID + its
#      ValidatingWebhookConfiguration render — declarative registration
#      for the ci-namespace consumer, not a hand-rolled entry-create
#      script.
#
# hk runs this as the `spire-verify` step (check layer). It needs
# network (helm pull) — same class as openbao-verify.sh. Offline /
# repo-down: prints a skip line and exits 0, so a flapping upstream repo
# does not red the whole check.
#
# Test seams (bats): TOOLBOX_SPIRE_LOCK overrides the lock path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$(cd "$SCRIPT_DIR/../spire" && pwd)"
LOCK="${TOOLBOX_SPIRE_LOCK:-$UNIT_DIR/spire.lock}"

die() {
	echo "spire-verify: $*" >&2
	exit 1
}
skip() {
	echo "spire-verify: $* — skipping (network gate)"
	exit 0
}
val() { sed -n "s/^$1=//p" "$LOCK"; }

# classify_failure <stderr text> — same classification as
# openbao-verify.sh's: true (0) for a permanent/config-shaped failure
# that should fail this gate CLOSED; false (1) for transient network
# unreachability (registry down, DNS, timeout) — skip, not die.
classify_failure() {
	case "$1" in
	*'dial tcp'* | *'i/o timeout'* | *'context deadline exceeded'* | \
		*'no such host'* | *'connection refused'* | \
		*' 404 '* | *': not found'*)
		return 1 ;;
	*)
		return 0 ;;
	esac
}

command -v helm >/dev/null || die "helm not on PATH"
[ -f "$LOCK" ] || die "lock file not found: $LOCK"

chart_repo="$(val chart_repository)"
crds_version="$(val spire_crds_chart_version)"
crds_digest="$(val spire_crds_chart_digest)"
spire_version="$(val spire_chart_version)"
spire_digest="$(val spire_chart_digest)"

{ [ -n "$chart_repo" ] && [ -n "$crds_version" ] && [ -n "$crds_digest" ] &&
	[ -n "$spire_version" ] && [ -n "$spire_digest" ]; } || die "lock file $LOCK is missing a field"
case "$crds_digest" in sha256:*) ;; *) die "spire_crds_chart_digest is not sha256:<hex>: '$crds_digest'" ;; esac
case "$spire_digest" in sha256:*) ;; *) die "spire_chart_digest is not sha256:<hex>: '$spire_digest'" ;; esac

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

pull_and_verify() {
	local chart="$1" version="$2" want_digest="$3"
	echo "spire-verify: helm pull $chart --version $version"
	helm pull "$chart" --repo "$chart_repo" --version "$version" \
		--destination "$workdir" 2>"$workdir/helm-pull-$chart.err" || {
		err="$(cat "$workdir/helm-pull-$chart.err")"
		if classify_failure "$err"; then
			die "helm pull failed for $chart:$version (not a network issue): $err"
		fi
		skip "cannot reach $chart_repo (registry down / offline)"
	}
	local tgz="$workdir/$chart-$version.tgz"
	[ -f "$tgz" ] || die "expected $tgz after helm pull, not found"
	local got_digest
	got_digest="sha256:$(shasum -a 256 "$tgz" | cut -d' ' -f1)"
	[ "$got_digest" = "$want_digest" ] ||
		die "$chart:$version resolves to $got_digest, lock says $want_digest — a mutated upstream release or a stale lock"
}

# --- 1/2. pull + digest-verify both charts -------------------------------
pull_and_verify "spire-crds" "$crds_version" "$crds_digest"
pull_and_verify "spire" "$spire_version" "$spire_digest"

crds_tgz="$workdir/spire-crds-$crds_version.tgz"
spire_tgz="$workdir/spire-$spire_version.tgz"

# --- 3. render spire-crds and assert the CRDs exist ----------------------
crds_rendered="$workdir/crds-rendered.yaml"
helm template spire-crds "$crds_tgz" >"$crds_rendered" 2>"$workdir/helm-crds.err" || {
	err="$(cat "$workdir/helm-crds.err")"
	if classify_failure "$err"; then
		die "helm template (spire-crds) failed (not a network issue): $err"
	fi
	skip "helm template (spire-crds) failed (offline / registry): $(tail -1 "$workdir/helm-crds.err")"
}

# --- 4. render spire with the same values main.tf sets -------------------
values="$workdir/values.yaml"
{
	echo 'global:'
	echo '  spire:'
	echo '    trustDomain: toolbox.local'
	echo 'spiffe-csi-driver: { enabled: false }'
	echo 'spiffe-oidc-discovery-provider: { enabled: false }'
	echo 'tornjak-frontend: { enabled: false }'
	echo 'spike-keeper: { enabled: false }'
	echo 'spike-nexus: { enabled: false }'
	echo 'spike-pilot: { enabled: false }'
	echo 'spire-identity-exchange: { enabled: false }'
	echo 'upstream: { enabled: false }'
	echo 'spire-agent:'
	echo '  enabled: true'
	echo '  trustBundleFormat: pem'
	echo 'spire-server:'
	echo '  enabled: true'
	echo '  serviceAccount:'
	echo '    name: spire-server'
	echo '  controllerManager:'
	echo '    enabled: true'
	echo '  upstreamAuthority:'
	echo '    vault:'
	echo '      enabled: true'
	echo '      vaultAddr: "https://openbao.openbao.svc.cluster.local:8200"'
	echo '      pkiMountPoint: "pki"'
	echo '      caCert:'
	echo '        type: Configmap'
	echo '        name: spire-vault-ca'
	echo '      k8sAuth:'
	echo '        enabled: true'
	echo '        k8sAuthMountPoint: "kubernetes"'
	echo '        k8sAuthRoleName: "spire_server"'
	echo '        token:'
	echo '          audience: "https://openbao.openbao.svc.cluster.local:8200"'
	echo '  bundlePublisher:'
	echo '    k8sConfigMap:'
	echo '      enabled: true'
	echo '      format: pem'
	echo '      namespace: zot'
} >"$values"

rendered="$workdir/rendered.yaml"
helm template spire "$spire_tgz" -f "$values" -n spire >"$rendered" 2>"$workdir/helm.err" || {
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

check "spire-crds ships the ClusterSPIFFEID CRD" \
	"grep -qE 'name: clusterspiffeids\\.spire\\.spiffe\\.io' '$crds_rendered'"
check "spire-crds ships the ClusterFederatedTrustDomain CRD" \
	"grep -qE 'name: clusterfederatedtrustdomains\\.spire\\.spiffe\\.io' '$crds_rendered'"

check "spire-server is a StatefulSet (not a Deployment)" \
	"grep -qxE 'kind: StatefulSet' '$rendered' && ! grep -qxE 'kind: Deployment' '$rendered'"
check "spire-server's ServiceAccount name is the explicit override" \
	"grep -qE '^\\s+serviceAccountName: spire-server\$' '$rendered'"
check "spire-agent is a DaemonSet" \
	"grep -qxE 'kind: DaemonSet' '$rendered'"
check "vault upstreamAuthority wired to OpenBao's pki mount and kubernetes-auth role" \
	"grep -qF '\"pki_mount_point\": \"pki\"' '$rendered' && grep -qF '\"k8s_auth_mount_point\": \"kubernetes\"' '$rendered' && grep -qF '\"k8s_auth_role_name\": \"spire_server\"' '$rendered'"
check "k8sPSAT TokenReview ClusterRole is present" \
	"grep -qE 'resources: \\[tokenreviews\\]' '$rendered'"
check "controller-manager's default ClusterSPIFFEID is present (declarative registration, not a hand-rolled entry-create script)" \
	"grep -qE 'kind: ClusterSPIFFEID' '$rendered' && grep -qE 'kind: ValidatingWebhookConfiguration' '$rendered'"
check "the default ClusterSPIFFEID covers ns ci (excludes only spire's own namespaces)" \
	"grep -qF 'operator: NotIn' '$rendered'"

[ "$fail" = 0 ] || die "rendered chart does not match the expected shape"

echo "spire-verify: OK — spire-crds $crds_version @ $crds_digest, spire $spire_version @ $spire_digest"
