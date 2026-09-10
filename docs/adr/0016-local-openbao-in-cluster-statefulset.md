# The local OpenBao runs in-cluster as an OpenTofu-owned raft StatefulSet, moved without rotating `approval-key`

The local dev OpenBao runs in the OrbStack cluster as a single-replica raft
StatefulSet (`environments/local/openbao/`), deployed by
`openbao-bootstrap.sh` — a one-time imperative bridge, model
`flux-bootstrap.sh` — then left steady-state. **Phase A** is a tofu
`helm_release` (chart `openbao/openbao` 0.29.4, image `v2.6.2`, both
digest-pinned out of band because the helm provider cannot pin an OCI chart
by digest). **Phase C** is tofu `vault_*` — a `sops` `aes256-gcm96` Transit
key, a decrypt-only policy, the Kubernetes ServiceAccount auth method + a
`flux_sops` role. It is OpenTofu-owned substrate, exempt from every
reconcile loop ([ADR 0015](0015-flux-precedes-in-cluster-openbao-gitrepository-plain-yaml.md))
— there is no Flux `HelmRelease` for OpenBao.

Why in-cluster: the host loopback listener (`environments/local/openbao/`,
[ADR 0010](0010-local-openbao-machine-global-static-seal.md)) cannot serve
cluster pods — the blocker in front of T8 (Tekton Chains provenance). TLS
comes from cert-manager (selfSigned root → CA → `openbao-tls` leaf).

Why a key-preserving `bao operator raft snapshot restore -force`, not a
fresh `bao operator init`: `approval-key` (`ecdsa-p256`, Transit) signs
every approval attestation, and `attestation/cosign-approval.pub` is
committed and re-verified on every consumer launch
([ADR 0005](0005-consume-verifies-against-committed-pubkey.md)). A fresh init
mints a new key and strands every past attestation. The bridge restores the
host's raft store into the cluster instance and **hard-fails unless the
in-cluster `approval-key` public half is byte-identical to the committed
file**. `approval-key` and the `transit` mount are never tofu-managed
(`openbao-verify.sh` greps the `.tf`).

Static-seal auto-unseal carries over from [ADR 0010](0010-local-openbao-machine-global-static-seal.md)
— a 32-byte `file://` key, now delivered as a `0600`-file-sourced Kubernetes
Secret mounted at `/openbao/seal`. The "`0600` files, the machine is the
trust boundary" model carries over from
[ADR 0011](0011-local-openbao-secrets-are-files-no-fnox.md); custody is
unchanged.

Genesis and disaster: with the host daemon retired there is no from-scratch
bootstrap — `openbao-bootstrap.sh` restores from the off-machine
`snapshots/` bundle (a live pre-migration host daemon is still accepted as a
source when one is present). Losing the bundle with no host daemon makes
`approval-key` unrecoverable; past approvals still verify against the
committed pubkey (ADR 0005), so it is a "resume signing" disaster — fresh
init → re-export pubkey → re-sign the current image → re-record
`current-image.txt`
([ADR 0006](0006-approval-selection-is-attestation-digest-pin.md)). Blast
radius: future signing only. A
declarative recovery design (cluster-sourced snapshots, tfstate backup) is
deferred — `TODOS.md` § T-DR.

Status: accepted. **Supersedes
[ADR 0010](0010-local-openbao-machine-global-static-seal.md)** — the
machine-global pitchfork daemon is retired for the in-cluster StatefulSet;
static-seal auto-unseal survives. **Amends
[ADR 0011](0011-local-openbao-secrets-are-files-no-fnox.md)** — the seal key
is now also a Kubernetes Secret, sourced from the same `0600` file. The
host `pitchfork` daemon and its `environments/local/openbao/` tofu unit are
retired; the in-cluster unit took the bare `openbao` name. Does not touch
[ADR 0012](0012-local-openbao-is-environment-nested.md) (the `modules/`
question — a later ADR revisits that) or
[ADR 0015](0015-flux-precedes-in-cluster-openbao-gitrepository-plain-yaml.md).
