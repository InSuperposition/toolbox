#!/usr/bin/env bash
set -euo pipefail

# hk `kubeconform-cert-manager` step for environments/local/cert-manager/
# AND environments/local/trust-manager/ — static schema validation of the
# dev-PKI CRs (cert-manager.io/v1 ClusterIssuer + Certificate, reconciled by
# the `cert-manager-pki` Flux Kustomization) plus the trust-manager Bundle
# (trust.cert-manager.io/v1alpha1, reconciled by `trust-manager-bundles`).
# trust-manager is cert-manager's sibling (CLAUDE.md § Tool Boundaries) —
# one gate covers both rather than a second near-identical wrapper.
#
# A wrapper, not an inline hk command: the `-schema-location` template
# ({{.ResourceKind}}) collides with hk's own command templating (same
# reason as environments/local/scripts/flux-kubeconform.sh and
# ci/scripts/kubeconform-scan.sh).
#
# Schemas are the CRD schemas vendored from the pinned cert-manager and
# trust-manager releases at environments/local/cert-manager/tests/crd-schemas/
# — regenerate on a chart bump (see environments/local/flux/cert-manager.lock
# / trust-manager.lock's headers).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CM_DIR="$(cd "$SCRIPT_DIR/../cert-manager" && pwd)"
TM_DIR="$(cd "$SCRIPT_DIR/../trust-manager" && pwd)"
SCHEMAS="$CM_DIR/tests/crd-schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

exec kubeconform -strict -summary \
	-ignore-filename-pattern 'tests/' \
	-ignore-filename-pattern 'kustomization.yaml' \
	-schema-location default \
	-schema-location "$SCHEMAS" \
	"$CM_DIR" "$TM_DIR"
