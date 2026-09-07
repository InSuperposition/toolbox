# attestation

## Abstract

The consumer-agnostic **sign + verify seam** for the
digest-as-source-of-truth pipeline (`docs/designs/digest-as-source-of-truth.md`,
[ADR 0013](../docs/adr/0013-attestation-seam-is-consumer-agnostic.md)). A
human reads an image's build evidence and signs an approve/reject decision
as an in-toto attestation over the image digest; any consumer of an
approved image verifies a digest-pinned attestation before running it.

This concern **owns** the sign/verify/preflight scripts,
`verdict-approved.cue`, and `cosign-approval.pub`. It **may depend on**
`tests/lib` only. It never names a consumer — the forbidden edge
`attestation ─╳▶ deploy/*` is machine-checked
(`docs/designs/repo-structure.md` § Enforcement).

## Files

| File | Role |
|---|---|
| `scripts/attestation-sign.sh` | `mise run attestation:sign` — evidence → human decision → signed attestation. The one real-logic script in the pipeline. Signs via `openbao://approval-key` (OpenBao Transit); always writes a signed record for either verdict, except a clean abort at the prompt. Prints the new attestation's digest — the selection key. |
| `scripts/attestation-verify.sh` | `mise run attestation:verify` — the shared verify seam. Fetches one digest-pinned attestation, checks its signature against the committed `cosign-approval.pub`, subject digest, predicate type, and `verdict == approved`. Never touches OpenBao ([ADR 0005](../docs/adr/0005-consume-verifies-against-committed-pubkey.md)). Exit 0 valid / 1 terminal / 2 bad args / 3 retryable. |
| `scripts/openbao-preflight.sh` | signing precondition — distinguishes unreachable / uninitialised / sealed / unauthorized / missing-key, exit 3, names the fix. |
| `scripts/lib/attestation.sh` | shared shell: the predicate-type string, the digest-reference check, local-registry detection. |
| `verdict-approved.cue` | `#Predicate` (permissive — sign side) + `#ApprovedStatement` (`verdict == approved` — verify side). One CUE file, two definitions ([ADR 0002](../docs/adr/0002-approval-record-not-digest-alone.md)). |
| `cosign-approval.pub` | committed public half of `openbao://approval-key` — what verify checks against. Written **only** by `mise run attestation:export-pubkey`; re-run + commit after a Transit key rotation. |
| `scripts/tests/*.bats`, `scripts/tests/helper.bash` | the matrix — a local `zot` + a throwaway cosign key via the `TOOLBOX_APPROVE_KEY` seam; the `openbao://` KMS leg is proved separately. |

## How a consumer reaches the verify seam

A consumer (`deploy/frontend/`) never sources these scripts across the
boundary. It calls `attestation-verify.sh` through the
`TOOLBOX_ATTESTATION_VERIFY` env seam (relative default), the same shape as
the `TOOLBOX_APPROVAL_PUBKEY` / `TOOLBOX_APPROVE_KEY` seams. See
`deploy/frontend/README.md`.

## Where the signing key lives

`openbao://approval-key` is an OpenBao Transit key provisioned by the
`environments/local/` tofu composition
([ADR 0004](../docs/adr/0004-approval-key-openbao-transit-not-acl.md),
[ADR 0012](../docs/adr/0012-local-openbao-is-environment-nested.md)) — not
owned here. `environments/local/scripts/openbao-bootstrap.sh` exports the
public half by calling `mise run attestation:export-pubkey` (a task call, a
runtime edge — it never writes into this directory directly).
