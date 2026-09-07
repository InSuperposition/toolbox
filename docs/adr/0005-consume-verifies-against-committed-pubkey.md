# The consumer verifies against the committed public key, never OpenBao

`attestation-verify.sh` (what `mise run frontend:deploy` and the launch
re-verify both reach, through the `TOOLBOX_ATTESTATION_VERIFY` seam) checks
a pinned attestation against `attestation/cosign-approval.pub` — exported
once from `openbao://approval-key` at bootstrap and committed to the repo —
and never calls OpenBao. Only `attestation-sign.sh` (the signing side) needs
OpenBao up and unsealed.

Why: it decouples consumption from signing availability. Losing the OpenBao
raft store stops *future* signing but leaves every past approval verifiable,
so a disk loss is a "resume signing" problem, not a "the gate is down"
problem. Re-export and re-commit `attestation/cosign-approval.pub` after any
Transit key rotation (`mise run attestation:export-pubkey`), or the consumer
verifies new signatures against a stale key.
