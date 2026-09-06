# The trust boundary is an approval record on the digest, not the digest alone

A digest establishes *content identity*, not *authority*. If a pull runs
merely because the reference contains `@sha256:`, we have enforced
addressing syntax, not trust. The consume-side gate therefore requires an
explicit, signed **approval record** attached to the digest (an in-toto
attestation), and only a digest carrying a valid approval is consumable.

Why: raised by a cross-model review of the original premise ("digest =
trust"). A digest anyone can compute is not an authorization. Provenance
and SBOM referrers are evidence a human reads; neither is the gate — a
build with provenance + SBOM but no valid approval is still rejected.

Refined by [0006](0006-approval-selection-is-attestation-digest-pin.md)
(which approval record counts) and
[0005](0005-consume-verifies-against-committed-pubkey.md) (what the
consumer verifies against).
