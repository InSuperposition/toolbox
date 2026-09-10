# trust-manager distributes the Kyverno CA-bundle ConfigMap on the dev reference cluster

The T7c R1a spike proved Kyverno's admission controller can trust the
cert-manager dev CA for the HTTPS zot pull via the chart's
`admissionController.caCertificates` value, but that mount **replaces** the
container's whole trust store (`/etc/ssl/certs/ca-certificates.crt`, no
merge) — so a bare dev-CA value would cost Kyverno every public registry.
We install **trust-manager** (cert-manager's sibling, `quay.io/jetstack`):
a `Bundle` CR merges `useDefaultCAs: true` (a pinned Debian public-root
snapshot the chart ships as an init container) with the live `toolbox-dev-ca`
Secret into one ConfigMap, which Kyverno then mounts via
`caCertificates.volume` (T7c R1b-ii). This is the enforce-stage half of the
"who mounts the dev CA" question (ADR 0018/0020); the zot server cert is the
other half (a `zot-tls` leaf, R1b-ii).

Chosen over a committed concatenated PEM ConfigMap because the dev CA is a
cert-manager-managed `Certificate` that renews on its own cycle — a frozen
copy silently stops validating leaves at renewal, whereas trust-manager
tracks the Secret. Chosen over the `caCertificates.data` string value
because that shadows the roots the Kyverno image already ships and is a
~150 KB blob in a HelmRelease. The cost accepted: a new pinned tool with its
own controller, ValidatingWebhookConfiguration, CRD, and bump cadence, for
what is one consumer today.

## Scope

- **R1b-i installs the tool only** — `trust-manager-helmrelease.yaml` +
  `trust-manager.lock` (both component images digest-pinned; the
  `trust-pkg-debian-trixie` package image is the actual public-trust input
  and is **frozen at its pinned digest**, not auto-refreshing — only the
  dev-CA half is dynamic). No `Bundle` CRs, no `secretTargets`.
- **The `Bundle` CRs land in R1b-ii**, in their own dir
  `environments/local/trust-manager/` under a dedicated Flux `Kustomization`
  (mirrors `cert-manager-pki.yaml`) — a `trust.cert-manager.io` custom kind
  in the `flux-system` inventory would deadlock the whole apply on the
  unknown CRD.
- **trust-manager owns the Kyverno CA-bundle ConfigMap. That is the whole
  mandate.** Whether buildkitd (which takes a per-registry CA file) and Flux
  source-controller (which takes a per-`OCIRepository` `certSecretRef`
  Secret) also route their CA trust through trust-manager — which would need
  `secretTargets` and its Secret RBAC — is an R1b-ii decision made with the
  manifests in hand, at the lowest privilege that works.

## Consequences

- `dependsOn` the `cert-manager` HelmRelease: trust-manager's own
  ValidatingWebhookConfiguration (`failurePolicy: Fail`) gets its `caBundle`
  from a chart-created self-signed Issuer + `Certificate`, injected by
  cert-manager's cainjector — independent of `toolbox-dev-ca`. The
  `trust-manager-reconcile` chainsaw test asserts that cert is Ready, the
  `caBundle` is injected, and a dry-run `Bundle` apply passes the webhook —
  "HelmRelease Ready" alone does not prove any of that.
- This ADR establishes **installation and the ConfigMap mechanism**. It does
  **not** assert that Kyverno hot-reloads a changed ConfigMap (a mounted
  `subPath` does not update in place — R1b-ii verifies whether a pod roll is
  needed) and does **not** solve CA rotation: replacing the `toolbox-dev-ca`
  key mid-rotation briefly leaves old and new roots mutually non-validating
  for every leaf and every distributed bundle. That runbook is an open
  `TODOS.md` item, not covered here.
- The trust-manager chart is not cosign-signed (same as OpenBao /
  cert-manager / Kyverno), so the `OCIRepository` pins `ref.digest` with no
  `spec.verify`. The component images are keyless-signed (Fulcio) but pinned
  by digest in git, reviewed in the PR — no runtime image `spec.verify`
  (`cert-manager.lock` decision `d8e2b203`).
