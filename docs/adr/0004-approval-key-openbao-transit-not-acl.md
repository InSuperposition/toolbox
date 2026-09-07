# The approval is signed with a dedicated OpenBao-Transit cosign key

Possession of a dedicated `cosign` keypair — the *approval key*, private
half in OpenBao Transit (`approval-key`, `exportable=false`), never in the
Pipeline's cluster environment — is what distinguishes a real approval
referrer from the automated SBOM/provenance ones. `attestation-sign.sh`
signs via `cosign attest --key openbao://approval-key`; the consumer trusts
only a referrer that verifies against that key.

Considered and rejected: a registry ACL restricting who can push an
approval-typed referrer (zot's ACL is identity + repo-path + action scoped,
with no per-artifactType distinction within one repo — verified), and a
Kubernetes RBAC restriction on which ServiceAccount a TaskRun may bind
(plain RBAC doesn't enforce that; Pod Security Admission or Kyverno would,
and Kyverno is this design's own deferred concern).

Reuses `cosign`, already pinned. `cosign generate-key-pair` is also why
`cosign` is a pinned tool at all (Tekton Chains' signer needs it).
