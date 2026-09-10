# A Kyverno ImageValidatingPolicy runs on the dev reference cluster, not only in production

`docs/designs/digest-as-source-of-truth.md` filed Kyverno admission enforcement
entirely under "negative space — production cluster only". This ADR narrows that:
**one** `ImageValidatingPolicy` runs on the local OrbStack *reference* cluster,
verifying the cosign approval attestation on the `cv_frontend` image digest at
pod admission — the declarative equivalent of `frontend-serve.sh`'s launch
re-verify, for the in-cluster delivery path (Plan B K1, amends the framing in
ADR 0018's "enforce" stage). This is consistent with Flux, OpenBao,
cert-manager, and Tekton already running there: the repo *is* a reference
deployment, and an admission check that only ever runs in an environment this
repo does not operate is an untested assertion. The `ci`-namespace
privilege-scoping policies (PSA scalpel, build-pod `securityContext`
enforcement) stay deferred to the production Kyverno module + the Cilium
planning session.

## Considered options

- **Keep Kyverno purely deferred, rely on `frontend-serve.sh` re-verify for the
  container path only.** Rejected: the in-cluster `cv_frontend` Deployment (ADR
  0019) has no launch re-verify — nothing checks the approval attestation before
  the Pod runs. The GitOps path would be strictly weaker than the pitchfork path.
- **Mutate the image to a verified digest at admission instead of denying.**
  Rejected (ADR 0018): an invisible admission rewrite is worse for review than a
  denied Pod with a rendered manifest. `mutateDigest: false`, deny-only.

## Consequences

- **Kyverno is pinned to v1.19.1 / chart 3.9.1** (`environments/local/flux/kyverno.lock`).
  Earlier releases either SIGSEGV on toolbox's keyed + OCI-referrer + ignore-tlog
  path (kyverno#16435, fixed in v1.19.0) or lack later IVPol hardening. A K1
  build-time spike live-proved semantic equivalence to `attestation-verify.sh`
  on v1.19.1 for all four ADR-0006 cases before Kyverno was committed as the
  k8s-path verifier.
- **`attestation-sign.sh` now writes two `dev.sigstore.bundle.*` manifest
  annotations** on the attestation referrer. Kyverno's discovery
  (`cosign.GetBundles`) filters on them; a bare `oras attach` referrer is
  invisible to it. `attestation-verify.sh` is unaffected (it is handed the
  digest and reads the layer, not the annotations).
- **The verified image + attestation must be pulled from GHCR (HTTPS), not the
  in-cluster zot.** Kyverno's referrer-discovery call does not honour
  `--allowInsecureRegistry` for a plain-HTTP registry. An in-cluster-zot verify
  path (a TLS-fronted zot, or a loopback port-forward) stays deferred — `TODOS.md`
  T12.
- The Kyverno chart is **not** cosign-signed, so the OCIRepository pins
  `ref.digest` with no `spec.verify` — same shape as the OpenBao and
  cert-manager charts.
