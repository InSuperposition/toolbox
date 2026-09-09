# environments/local/openbao-cluster — the in-cluster OpenBao tofu unit

## Abstract

Provisions the local dev OpenBao as a **single-replica, tofu-owned raft
StatefulSet** in the OrbStack cluster, so cluster workloads
(kustomize-controller for SOPS, Tekton Chains for provenance) can reach it
over TLS with Kubernetes ServiceAccount auth — the loopback listener of
`environments/local/openbao/` cannot serve pods.

T7c Increment 4 (`~/.claude/plans/t7c-increment4-in-cluster-openbao.md`,
`docs/adr/0015`, `docs/adr/0016`). **This directory is Increment 4a: Phase A
only — the `helm_release`.** Increment 4d retires `environments/local/openbao/`,
renames this unit back to the bare `openbao`, and repoints
`environments/local/provider.tf`.

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
| **A** | `helm_release` — the pinned chart, single-replica values, TLS listener, `seal "static"` stanza. cert-manager + the dev CA (`environments/local/flux/cert-manager-*`) ship here too. | **4a (here)** |
| **B** | namespace `openbao` + the `openbao-tls` leaf `Certificate` + the seal `Secret`; first `bao operator init` once; a key-preserving `raft snapshot restore -force` | 4b (the bridge script, not `.tf`) |
| **C** | `provider "vault"` + `vault_mount`/`vault_transit_secret_backend_key` (`approval-key` imported, `sops` new) + `vault_policy` + `vault_auth_backend "kubernetes"` + role | 4c |

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
- `tofu test` (`tests/helm_values.tftest.hcl`, `mock_provider`) — the
  `helm_release` values plan as expected; `create_namespace` stays false.
- An ephemeral `[k8s]` chainsaw run (release + throwaway seal + throwaway
  cert in a scratch namespace → `openbao-0` Running, `Seal Type: static`,
  `Storage Type: raft`, TLS endpoint live, torn down) lands with the
  bootstrap bridge in **4b**, where the real seal Secret + cert-manager leaf
  exist — 4a stands up nothing permanent, and the bridge's live acceptance
  run is the genuine end-to-end proof.
