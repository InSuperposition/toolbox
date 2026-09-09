#!/usr/bin/env bash
set -euo pipefail

# hk `kubeconform` step for the ci/ concern (CLAUDE.md § Testing Strategy —
# static schema validation, no cluster, fast pre-merge gate). A wrapper,
# not an inline hk command, because the kubeconform -schema-location
# template ({{.ResourceKind}}) collides with hk's own command templating.
#
# Tekton ships no standalone validator, so the Task is checked against the
# v1 CRD schema vendored from the pinned release at ci/tests/crd-schemas/
# (regenerate on a Tekton bump — environments/local/README.md § Tekton).
# The CRD schema declares no `additionalProperties: false`, so this catches
# structural errors (missing / mistyped fields), not unknown keys — the
# Tekton admission webhook (ci/tests chainsaw, [k8s]) is the deep check.
#
# ci/tests/**.yaml are chainsaw Tests (a different CRD), not Tekton
# manifests — only the manifest dirs are validated.
#
# Each manifest dir also carries a kustomization.yaml (kustomize.config.k8s.io,
# not a cluster kind — the per-path inventory Flux reconciles, T7c Increment
# 2). It has no CRD schema and is skipped by filename, same as the
# environments/local/flux/ gate does.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMAS="$CI_DIR/tests/crd-schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

dirs=()
for d in tasks runtime pipelines; do
	[ -d "$CI_DIR/$d" ] && dirs+=("$CI_DIR/$d")
done

exec kubeconform -strict -summary \
	-ignore-filename-pattern 'kustomization.yaml' \
	-schema-location default \
	-schema-location "$SCHEMAS" \
	"${dirs[@]}"
