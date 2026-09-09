#!/usr/bin/env bash
set -euo pipefail

# environments/local/scripts/flux-bootstrap.sh — the ONE-TIME imperative bridge
# that installs flux-operator. After this, everything is declarative: the
# committed FluxInstance + flux-operator-helmrelease.yaml (helm-controller
# adopts the release) + the zot Kustomization take over. Re-run only for
# disaster recovery — it is idempotent (`helm upgrade --install` + `apply`).
#
# Steps: precondition (cluster reachable) -> cosign-verify the PINNED chart
# digest -> `helm upgrade --install` that digest -> wait operator + CRD ->
# apply the FluxInstance -> wait Ready. The digest IS the trust boundary
# (ADR 0001); a tag is never installed, and there is NO
# `--insecure-ignore-tlog` fallback.
#
# Test seams (environments/local/scripts/tests/flux-bootstrap.bats):
#   TOOLBOX_FLUX_LOCK          override the lock-file path
#   TOOLBOX_FLUX_KUBE_CONTEXT  override the kube-context (default orbstack)
#   TOOLBOX_FLUX_CHART_REPO    override the chart OCI repo
#   TOOLBOX_FLUX_SYNC_REF      git ref the FluxInstance syncs (default
#                              refs/heads/main; a feature-branch bootstrap /
#                              the live acceptance run sets its own branch)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUX_DIR="$(cd "$SCRIPT_DIR/../flux" && pwd)"

LOCK="${TOOLBOX_FLUX_LOCK:-$FLUX_DIR/flux-operator.lock}"
CONTEXT="${TOOLBOX_FLUX_KUBE_CONTEXT:-orbstack}"
CHART_REPO="${TOOLBOX_FLUX_CHART_REPO:-ghcr.io/controlplaneio-fluxcd/charts/flux-operator}"
SYNC_REF="${TOOLBOX_FLUX_SYNC_REF:-refs/heads/main}"
NS="flux-system"

# helm-controller stores releases as Secrets; never inherit a configmap/sql
# driver from an ambient HELM_DRIVER so the adopt-on-first-reconcile matches.
export HELM_DRIVER="secret"

die() {
	echo "flux-bootstrap: $*" >&2
	exit 1
}
val() { sed -n "s/^$1=//p" "$LOCK"; }

[ -f "$LOCK" ] || die "lock file not found: $LOCK"
version="$(val version)"
chart_digest="$(val chart_digest)"
image_digest="$(val operator_image_digest)"
issuer="$(val cosign_issuer)"
identity="$(val cosign_identity_regexp)"
{ [ -n "$version" ] && [ -n "$chart_digest" ] && [ -n "$image_digest" ] &&
	[ -n "$issuer" ] && [ -n "$identity" ]; } || die "lock file $LOCK is missing a field"
case "$chart_digest" in sha256:*) ;; *) die "chart_digest is not sha256:<hex>: '$chart_digest'" ;; esac
case "$image_digest" in sha256:*) ;; *) die "operator_image_digest is not sha256:<hex>: '$image_digest'" ;; esac

kubectl --context "$CONTEXT" cluster-info >/dev/null 2>&1 ||
	die "kube-context '$CONTEXT' unreachable — is \`orb start k8s\` up?"

echo "flux-bootstrap: cosign verify $CHART_REPO@$chart_digest"
cosign verify \
	--certificate-oidc-issuer="$issuer" \
	--certificate-identity-regexp="$identity" \
	"$CHART_REPO@$chart_digest" >/dev/null ||
	die "cosign verify failed for $CHART_REPO@$chart_digest — refusing to install"

echo "flux-bootstrap: helm upgrade --install flux-operator (chart @$chart_digest)"
helm upgrade --install flux-operator "oci://$CHART_REPO@$chart_digest" \
	--kube-context "$CONTEXT" \
	--namespace "$NS" --create-namespace \
	--set "image.tag=v${version}@${image_digest}" \
	--wait --timeout 5m

# `deployment/` not `deploy/` — the concern-boundary lint (rules/boundary-shell-deploy-ref)
# regex-matches the substring `deploy/`.
kubectl --context "$CONTEXT" -n "$NS" rollout status deployment/flux-operator --timeout=120s
kubectl --context "$CONTEXT" wait --for=condition=Established \
	crd/fluxinstances.fluxcd.controlplane.io --timeout=60s

echo "flux-bootstrap: applying FluxInstance (sync ref: $SYNC_REF)"
kubectl --context "$CONTEXT" apply -f "$FLUX_DIR/flux-instance.yaml"
kubectl --context "$CONTEXT" -n "$NS" patch fluxinstance flux --type merge \
	-p "{\"spec\":{\"sync\":{\"ref\":\"${SYNC_REF}\"}}}"

kubectl --context "$CONTEXT" -n "$NS" wait --for=condition=Ready \
	fluxinstance/flux --timeout=5m

echo "flux-bootstrap: FluxInstance Ready. Flux now reconciles environments/local/flux/ from git ($SYNC_REF)."
