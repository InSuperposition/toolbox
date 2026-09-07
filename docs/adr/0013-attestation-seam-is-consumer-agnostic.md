# The attestation sign/verify seam is its own concern, not part of `deploy/frontend/`

The approval sign + verify + preflight seam moves to a top-level
`attestation/` directory: `attestation-sign.sh` (was
`deploy/frontend/scripts/approve.sh`), `attestation-verify.sh` (was
`verify-approval.sh`), `openbao-preflight.sh`, `verdict-approved.cue`, and
`cosign-approval.pub`. `deploy/frontend/` reaches the verifier through a
`TOOLBOX_ATTESTATION_VERIFY` env seam (relative default), the same shape as
the existing `TOOLBOX_APPROVAL_PUBKEY` / `TOOLBOX_APPROVE_KEY` seams.

Why: signing and verifying an approval record is consumer-agnostic — any
future consumer of an approved image needs the same verify seam, and the
signing side has no consumer at all. Filing it under `deploy/frontend/`
(its first and currently only consumer) inverts the dependency: a shared
seam would then live inside one of the things that depends on it, and a
second consumer would have to either reach across into `deploy/frontend/`
or copy the seam. The forbidden edge `attestation ─╳▶ deploy/*` is now
machine-checkable — a seam must never name its consumers.

Consequence: `openbao-bootstrap.sh` (under `environments/local/scripts/`)
must not write `cosign-approval.pub` directly across the new boundary — it
calls `mise run attestation:export-pubkey`, whose `--outfile` points at
`attestation/cosign-approval.pub`. The task call is a runtime edge, not a
file-path dependency.

Status: accepted. Part of the repo-structure restructure
(`docs/designs/repo-structure.md`).
