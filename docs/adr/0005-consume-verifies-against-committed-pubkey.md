# The consumer verifies against the committed public key, never OpenBao

`verify-approval.sh` (what `mise run consume` and the T5b launch re-verify
both call) checks a pinned attestation against
`deploy/frontend/cosign-approval.pub` — exported once from
`openbao://approval-key` at bootstrap and committed to the repo — and never
calls OpenBao. Only `approve.sh` (the signing side) needs OpenBao up and
unsealed.

Why: it decouples consumption from signing availability. Losing the OpenBao
raft store stops *future* signing but leaves every past approval verifiable,
so a disk loss is a "resume signing" problem, not a "the gate is down"
problem. Re-export and re-commit `cosign-approval.pub` after any Transit key
rotation (`mise run export-approval-pubkey`), or the consumer verifies new
signatures against a stale key.
