# environments/local/spire — the in-cluster SPIRE Server + Agent tofu unit

## Abstract

Provisions SPIRE Server + Agent in the OrbStack cluster as a **tofu-owned**
Helm release (SPIRE Phase 1, TODOS.md's phased workload-identity rollout).
Node-attests Agents via `k8s_psat`; the Server's intermediate CA is signed
by OpenBao's `pki` mount at runtime (docs/adr/0025), never a third
independent CA.

docs/adr/0026 covers why Server + Agent ship as ONE `helm_release`
(tofu-owned, same ADR-0016 test as OpenBao) rather than splitting the
Agent into a separate Flux-reconciled path.

## Goals

- SPIRE reachable in-cluster, its own CA chained to OpenBao's `pki`
  mount — one root of trust for the whole stack.
- Wholly OpenTofu-owned (same ADR-0016 test as OpenBao): a long-lived
  process minting its own signing keys, with a one-time bootstrap.
- Zero static credentials — spire-server authenticates to OpenBao via
  its own ServiceAccount token (k8s-auth), never a stored token.

## Constraints

- This unit never manages OpenBao's `pki` mount, policy, or k8s-auth
  role (`environments/local/openbao/`'s job, docs/adr/0025) — it only
  references the role NAME (`spire_server`) and the mount path (`pki`)
  by plain string, resolved at runtime, never via tofu-to-tofu state.
- The chart is pinned by content digest (`spire.lock`) since the repo is
  a classic (non-OCI) Helm repo — `spire-verify.sh` computes the real
  `sha256sum` of a `helm pull`'d `.tgz`, no `oras resolve` equivalent.
- `spire-server.serviceAccount.name` is set explicitly to `spire-server`
  — the chart's own fullname-derived default would NOT produce that
  name for release name `spire`, and OpenBao's k8s-auth role already
  binds the literal name.
- The `caCert` OpenBao's TLS listener is verified against comes from a
  **dedicated** `trust-manager` `Bundle` CR
  (`environments/local/trust-manager/spire-vault-ca.yaml`), not the
  shared Kyverno/ci one — different required key name (`ca.crt`, the
  vault plugin's hardcoded mount expectation vs. the shared Bundle's
  `ca-certificates.crt`).

## Phases

| Phase | What |
|---|---|
| **A** | `helm_release.spire_crds` — the CRDs the umbrella chart needs (not a Chart.yaml dependency of `spire` — a genuinely separate release, confirmed live). |
| **B** | `helm_release.spire` — spire-server + spire-agent, one release, `depends_on` Phase A. `wait = false` (same non-wait reasoning as OpenBao's Phase A — spire-server's readiness depends on a runtime OpenBao round-trip). |

No Phase C — unlike OpenBao, this unit needs no post-restore API config;
everything is expressible via chart values.

## Inputs / Outputs

See `variables.tf` / `outputs.tf`.

## Verify / test

- `mise run local:spire:verify` — `spire-verify.sh`: asserts both
  charts' locked digests, then `helm template`s them and asserts
  `spire-crds`' CRDs render, `spire-server` renders a `StatefulSet` with
  `serviceAccountName: spire-server` and the vault upstreamAuthority
  block wired to `pki`/`spire_server`/`kubernetes`, `spire-agent` renders
  a `DaemonSet`, and the k8sPSAT ClusterRole/ClusterRoleBinding are
  present.
- `tofu test` (`mock_provider`) — `tests/*.tftest.hcl`.
- `environments/local/tests/spire/chainsaw-test.yaml` — `[k8s]` gated
  (`spire-chainsaw.sh` skips without a cluster and until
  `mise run local:spire:bootstrap` has run). Asserts the RUNNING
  post-bootstrap state: CRDs present, StatefulSet + DaemonSet Ready, the
  `spire-bundle` ConfigMap has non-empty `bundle.crt`, the
  `spire-vault-ca` ConfigMap has non-empty `ca.crt`.
- The bridge's own live check (`spire-server bundle show` returns a real
  intermediate-signed bundle, not a bare self-signed cert) is the
  genuine end-to-end proof that the OpenBao round-trip succeeded.
