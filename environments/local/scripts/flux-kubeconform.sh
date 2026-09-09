#!/usr/bin/env bash
set -euo pipefail

# hk `kubeconform` step for environments/local/flux/ — static schema
# validation of the Flux CRs (FluxInstance, OCIRepository, HelmRelease,
# Kustomization) reconciled onto the local cluster.
#
# A wrapper, not an inline hk command: the `-schema-location` template
# ({{.ResourceKind}}) collides with hk's own command templating (same
# reason as ci/scripts/kubeconform-scan.sh).
#
# Schemas are v1/v2 CRD schemas vendored from the pinned releases at
# environments/local/flux/tests/crd-schemas/ (Flux 2.9.5, flux-operator
# v0.59.0 — regenerate on a bump, see environments/local/README.md § Flux).
# They carry no additionalProperties:false, so this catches missing /
# mistyped fields, not unknown keys — the operator's CEL validation and a
# live `flux-bootstrap` apply are the deep checks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUX_DIR="$(cd "$SCRIPT_DIR/../flux" && pwd)"
SCHEMAS="$FLUX_DIR/tests/crd-schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

exec kubeconform -strict -summary \
	-ignore-filename-pattern 'tests/' \
	-schema-location default \
	-schema-location "$SCHEMAS" \
	"$FLUX_DIR"
