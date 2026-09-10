#!/usr/bin/env bash
set -euo pipefail

# hk `kubeconform-kyverno` step for environments/local/kyverno/ — static
# schema validation of the ImageValidatingPolicy (Plan B K1, docs/adr/0020)
# and the generated approval-pubkey ConfigMap, reconciled by the
# `kyverno-policy` Flux Kustomization.
#
# `kustomize build` first: the configMapGenerator reads
# attestation/cosign-approval.pub in place (one authored copy, no vendored
# second), which needs LoadRestrictionsNone — kustomize-controller runs that
# way by default, so this matches what Flux actually renders. Then
# kubeconform the rendered stream.
#
# A wrapper, not an inline hk command: the `-schema-location` template
# ({{.ResourceKind}}) collides with hk's own command templating (same reason
# as flux-kubeconform.sh / cert-manager-kubeconform.sh). The
# ImageValidatingPolicy v1 CRD schema is vendored from the pinned Kyverno
# chart at environments/local/kyverno/tests/crd-schemas/ — regenerate on a
# chart bump (see environments/local/flux/kyverno.lock's header).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KYV_DIR="$(cd "$SCRIPT_DIR/../kyverno" && pwd)"
SCHEMAS="$KYV_DIR/tests/crd-schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

kustomize build --load-restrictor LoadRestrictionsNone "$KYV_DIR" \
	| kubeconform -strict -summary \
		-schema-location default \
		-schema-location "$SCHEMAS" \
		-
