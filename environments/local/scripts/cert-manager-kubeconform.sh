#!/usr/bin/env bash
set -euo pipefail

# hk `kubeconform-cert-manager` step for environments/local/cert-manager/ —
# static schema validation of the dev-PKI CRs (cert-manager.io/v1
# ClusterIssuer + Certificate) reconciled by the `cert-manager-pki` Flux
# Kustomization.
#
# A wrapper, not an inline hk command: the `-schema-location` template
# ({{.ResourceKind}}) collides with hk's own command templating (same
# reason as environments/local/scripts/flux-kubeconform.sh and
# ci/scripts/kubeconform-scan.sh).
#
# Schemas are the v1 CRD schemas vendored from the cert-manager release at
# environments/local/cert-manager/tests/crd-schemas/ — regenerate on a chart
# bump (see environments/local/flux/cert-manager.lock's header + the
# cert-manager.crds.yaml release asset).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CM_DIR="$(cd "$SCRIPT_DIR/../cert-manager" && pwd)"
SCHEMAS="$CM_DIR/tests/crd-schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

exec kubeconform -strict -summary \
	-ignore-filename-pattern 'tests/' \
	-ignore-filename-pattern 'kustomization.yaml' \
	-schema-location default \
	-schema-location "$SCHEMAS" \
	"$CM_DIR"
