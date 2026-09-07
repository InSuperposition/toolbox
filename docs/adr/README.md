# Architecture Decision Records

One file per decision that is **hard to reverse**, **surprising without
context**, and **the result of a real trade-off**. Format: a title plus one
to three sentences (see `~/.claude/skills/grill-with-docs/ADR-FORMAT.md`).
Never rewrite an ADR to reverse it — add a new one and mark the old one
superseded.

| ADR | Decision |
|---|---|
| [0001](0001-digest-is-the-trust-boundary.md) | Digest is the enforced trust boundary; tags are convenience aliases |
| [0002](0002-approval-record-not-digest-alone.md) | The boundary is a signed approval *record* on the digest, not the digest alone |
| [0003](0003-tekton-pipelines-on-orbstack-k8s.md) | Tekton Pipelines + Chains on OrbStack k8s as the pipeline engine (A/B/C rejected) |
| [0004](0004-approval-key-openbao-transit-not-acl.md) | Approval signed with a dedicated OpenBao-Transit cosign key, not a registry ACL / k8s RBAC |
| [0005](0005-consume-verifies-against-committed-pubkey.md) | The consumer verifies against the committed public key, never OpenBao |
| [0006](0006-approval-selection-is-attestation-digest-pin.md) | The consumer pins one approval attestation by digest (supersedes "latest wins") |
| [0007](0007-distroless-dockerfile-not-buildpacks.md) | Distroless Node image from a hand-authored Dockerfile (supersedes Paketo buildpacks) |
| [0008](0008-arm64-only.md) | `linux/arm64` only (supersedes the amd64 constraint) |
| [0009](0009-demo-consumer-is-local-container-not-k8s.md) | The demo consumer is a local pitchfork container, not a k8s Deployment |
| [0010](0010-local-openbao-machine-global-static-seal.md) | Local OpenBao is one machine-global pitchfork daemon that auto-unseals from a static `file://` seal key |
| [0011](0011-local-openbao-secrets-are-files-no-fnox.md) | Local OpenBao's secrets are 0600 files beside its data — no fnox, no keychain (supersedes T3) |
| [0012](0012-local-openbao-is-environment-nested.md) | The local-OpenBao tofu unit lives under `environments/local/`, not `modules/` (breaks the sibling symmetry deliberately) |
| [0013](0013-attestation-seam-is-consumer-agnostic.md) | The attestation sign/verify seam is its own `attestation/` concern, not part of `deploy/frontend/` |
| [0014](0014-tekton-defs-are-oci-bundles-in-ci.md) | Tekton Task/Pipeline defs are digest-pinned OCI bundles in a `ci/` concern, not versioned dirs in `modules/` (supersedes the CLAUDE.md carve-out) |

Architecture: `docs/designs/`. Open work: `TODOS.md`.
