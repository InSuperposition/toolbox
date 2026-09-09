# environments/local/openbao-cluster — the in-cluster OpenBao tofu unit

## Abstract

Provisions the local dev OpenBao as a **single-replica, tofu-owned raft
StatefulSet** in the OrbStack cluster, so cluster workloads
(kustomize-controller for SOPS, Tekton Chains for provenance) can reach it
over TLS with Kubernetes ServiceAccount auth — the loopback listener of
`environments/local/openbao/` cannot serve pods.

T7c Increment 4 (`~/.claude/plans/t7c-increment4-in-cluster-openbao.md`,
`docs/adr/0015`, `docs/adr/0016`). **Phase A (the `helm_release`) shipped in
4a; the bootstrap bridge + first init + key-preserving restore shipped in
4b; Phase C (`provider "vault"` + the `vault_*` API config) shipped in 4c —
all applied by `../scripts/openbao-cluster-bootstrap.sh`.** Increment 4d
retires `environments/local/openbao/`, renames this unit back to the bare
`openbao`, and repoints `environments/local/provider.tf`.

## Goals

- OpenBao reachable in-cluster over HTTPS, raft-backed so a Transit key
  survives a pod restart.
- `approval-key` preserved **bit-for-bit** across the eventual move — a
  fresh `bao operator init` is a trust migration that breaks every past
  approval attestation (plan § B3). Increment 4b does a key-preserving raft
  snapshot restore, never a fresh init.
- Wholly OpenTofu-owned (ADR 0015 substrate rule). This is **not** a Flux
  `HelmRelease` — the secret store must not sit behind the reconcile loop
  that later depends on it for SOPS.

## Constraints

- No plaintext secret in repo **or tofu state**. This unit never sees the
  32-byte seal key or the raft store: the seal `Secret` is created by the
  bootstrap bridge (Increment 4b) from the on-machine `0600`
  `$OPENBAO_STATE_DIR/seal.key`; the TLS `Secret` is issued by cert-manager.
  `main.tf` references only their **names**.
- The chart is pinned. The OpenTofu helm provider cannot pin an OCI chart
  by digest ([hashicorp/terraform-provider-helm#1596](https://github.com/hashicorp/terraform-provider-helm/issues/1596)),
  so `main.tf` pins the **tag** and `openbao-cluster-verify.sh` + the bridge
  assert `crane digest <tag>` == `openbao-cluster.lock`'s `chart_digest`
  (fail closed) before any `tofu apply`. The server **image** is digest-pinned
  directly, via `server.image.tag = "<tag>@sha256:<digest>"`.

## Phases (this unit spans 4a → 4c)

| Phase | What | Increment |
|---|---|---|
| **A** | `helm_release` — the pinned chart, single-replica values, TLS listener, `seal "static"` stanza. cert-manager (`environments/local/flux/cert-manager-*`) + the dev CA (`environments/local/cert-manager/`) ship here too. | **4a (here)** |
| **B** | namespace `openbao` + the `openbao-tls` leaf `Certificate` + the seal `Secret`; first `bao operator init` once; a key-preserving `raft snapshot restore -force` | 4b (the bridge script, not `.tf`) |
| **C** | `provider "vault"` + the `vault_*` API config against the RESTORED instance: the **new** `sops` `vault_transit_secret_backend_key` (`aes256-gcm96`), a decrypt-only `vault_policy`, `vault_auth_backend "kubernetes"` + config (same-cluster shortcut — `kubernetes_host` only) + a `flux_sops` role bound to `kustomize-controller`/`flux-system`. **NEVER** the `transit` mount or `approval-key` (restore-managed — a tofu recreate is a key rotation; `openbao-cluster-verify.sh` greps the `.tf` and fails closed). No `kubernetes_cluster_role_binding` — the chart ships `system:auth-delegator` for the `openbao` SA. | 4c |

## Topology — "persistent single-node"

`server.ha.enabled: true` + `server.ha.raft.enabled: true` +
`server.ha.replicas: 1`. Raft with one voter is a supported single-node
mode. `server.affinity` is cleared (`""`) — the chart renders pod
anti-affinity whenever `ha.enabled`, not just at `replicas > 1`, and the one
replica must schedule on OrbStack's single node.
`server.ha.disruptionBudget.enabled: false` — a PDB would block the sole
pod's own drain. No agent-injector, no CSI provider (circular — it needs
OpenBao already running), no UI. HA/quorum is an
`environments/production/ secret-openbao` concern, not this one.

## Inputs / Outputs

See `variables.tf`. In 4a only the Phase-A inputs are consumed;
`openbao_cluster_endpoint`, `openbao_cluster_ca` and `transit_keys` are
declared now (stable contract across the sub-increments) and wired in 4c.

## Verify / test

- `mise run local:openbao-cluster:helm-verify` — `openbao-cluster-verify.sh`:
  asserts the locked digest, then `helm template`s the chart **by digest**
  and asserts exactly 1 replica, a StatefulSet, an HTTPS listener, a
  `seal "static"` stanza, the seal + TLS mounts, and **no** pod
  anti-affinity / PDB.
- `tofu test` (`mock_provider`) — `helm_values.tftest.hcl` (Phase A values)
  + `phase_c.tftest.hcl` (the SOPS key is AES + locked down, the policy is
  decrypt-only, the role is scoped to Flux, `approval-key` in `transit_keys`
  is a validation failure).
- `environments/local/tests/openbao-cluster/chainsaw-test.yaml` (4b) —
  `[k8s]` gated (`openbao-cluster-chainsaw.sh` skips without a cluster and
  until `mise run local:openbao-cluster:bootstrap` has run). Asserts the
  RUNNING post-migration state: the `openbao-tls` Certificate + Secret, the
  `openbao-seal` Secret, a single ready raft voter, `openbao-0` Running +
  Ready (Ready ⇒ unsealed — the readiness probe is `bao status`), the HTTPS
  Service. It does not run the bridge or tear down.
- The bridge's own hard assertion (`approval-key` byte-identical to
  `attestation/cosign-approval.pub`) + a manual
  `mise run local:openbao-cluster:bootstrap` acceptance run are the genuine
  end-to-end proof.
