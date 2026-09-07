// Approval-attestation schema and consume-side gate — ONE file, TWO uses.
//
// The digest-as-source-of-truth pipeline signs a human's approve/reject
// decision as an in-toto attestation over the built image digest
// (docs/designs/digest-as-source-of-truth.md § Architecture). This file is both the
// schema that decision is checked against before signing AND the policy the
// consumer checks a pinned attestation against before running the image.
//
//   approve.sh          cue vet <predicate>.json  -d '#Predicate'          verdict-approved.cue
//   verify-approval.sh  cue vet <in-toto-stmt>.json -d '#ApprovedStatement' verdict-approved.cue
//
// Why two definitions (Codex P1-3):
//   - #Predicate is PERMISSIVE — it accepts verdict "approved" OR "rejected".
//     approve.sh vets against it before signing so a reject record is a
//     well-formed, signed, durable audit entry, never a silent drop.
//   - #ApprovedStatement wraps the WHOLE in-toto statement (not the bare
//     predicate) and pins verdict to "approved". verify-approval.sh checks a
//     digest-pinned attestation against it, so a validly-signed "rejected"
//     record that a consumer pins by mistake fails the gate with a clear
//     "verdict rejected", and a good approval sitting next to a signed reject
//     still verifies when selected by its own digest (the selection model —
//     no "any reject poisons the image").
//
// Not JSON Schema: CUE is a schema language (satisfies this repo's "schemas
// required for core functionality"), and one CUE file avoids maintaining the
// permissive and the strict shape as two separate artifacts.

package approval

// The signed decision. schemaVersion is fixed at 1 — bump deliberately, with
// a matching consumer change, if the shape ever moves.
#Predicate: {
	schemaVersion: 1

	// The image digest this decision is about. Redundant with the in-toto
	// statement's subject digest on purpose: the signed predicate stands
	// alone as an audit record even detached from its OCI subject.
	digest: =~"^sha256:[0-9a-f]{64}$"

	verdict: "approved" | "rejected"

	// Free text — why. Required for both verdicts; a decision with no stated
	// reason is not an acceptable audit trail.
	reason: string & !=""

	// Who decided. In T5's interim auth this is self-asserted (anyone with
	// the OpenBao root token can write any value) — the "Auth + DX" planning
	// session replaces it with a per-member cryptographic identity. Still
	// required: an empty approver is never valid.
	approvedBy: string & !=""

	// RFC 3339 timestamp, self-asserted (no trusted timestamp authority in
	// T5). Audit metadata only — NEVER a selection or trust input.
	approvedAt: =~"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"

	// Digest of the trivy scan-report OCI referrer the decision was made
	// against — ties a verdict to the exact evidence it was read from.
	scanReportRef: =~"^sha256:[0-9a-f]{64}$"
}

// The consume-side gate. cosign / verify-approval.sh hand this the entire
// in-toto statement, so the constraint is expressed at statement level.
// `...` keeps it open — _type, subject, and any future statement fields pass
// through untouched; only predicateType and the predicate shape are pinned.
#ApprovedStatement: {
	predicateType: "https://insuperposition.github.io/toolbox/attestations/approval/v1"
	predicate: #Predicate & {verdict: "approved"}
	...
}
