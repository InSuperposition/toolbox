# The consumer pins one approval attestation by its own digest

`attestation-sign.sh` prints the new attestation's own digest; the consumer
records it and passes it to `mise run frontend:deploy -- <image-ref>
<attestation-digest>`. `attestation-verify.sh` fetches *that specific
attestation* and verifies it — it does not scan all referrers on the image.

Why: `cosign verify-attestation --policy` fails if *any* attestation of the
type on the image fails the policy (verified against cosign 3.1.3 source),
so a validly-signed `verdict: rejected` record sitting next to a good
approval would poison the image. Pinning by digest is what makes the
selection deterministic — a mistaken reject is just an unselected record, a
re-approval is a new selectable one, and only validly-signed records count.

Status: accepted. Supersedes two earlier ideas — "latest `approvedAt` wins"
(self-asserted timestamp, no trusted TA) and "reject is terminal"
(conflates evidence-review with content-ban; a typo reject would kill a
good digest forever). `approvedAt` is retained as an audit field only.

**Plan B M3:** `mise run frontend:publish` (the in-cluster delivery path) reaches this same seam — it verifies the pinned attestation before rendering/pushing, so the contract holds for both the pitchfork and the k8s consumer.
