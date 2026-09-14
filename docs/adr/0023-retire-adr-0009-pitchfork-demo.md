# The ADR-0009 pitchfork demo consumer is retired

`deploy/frontend/scripts/frontend-deploy.sh` / `frontend-serve.sh` and the
`[daemons.frontend]` pitchfork daemon are deleted, not repaired: T7c R4
deleted the GHCR packages the demo's restart path depended on, re-pushing
a live GHCR image was considered and rejected as a step backward, and the
in-cluster Flux delivery path (`frontend:publish`, ADR 0019/0021) has
already proven the same build→scan→approve→consume pipeline mechanism the
demo existed to demonstrate — the pitchfork container is now redundant
negative space, not a gap to fill.

The pitchfork path is given up, not replaced: it was the one path with a
**launch-time** re-verify of the approval attestation (ADR 0019 named this
as its distinguishing strength over Kyverno's admission-time-only check).
No path in this repo re-verifies after admission now — Kyverno's
`ImageValidatingPolicy` (ADR 0020) checks once, at pod creation, and an
already-running pod whose approval is later rejected is not re-checked by
anything. This gap already existed in the k8s path since ADR 0019/M3
shipped; retiring the pitchfork demo just removes the one place in the
repo that didn't have it.

Status: accepted. Supersedes [ADR 0009](0009-demo-consumer-is-local-container-not-k8s.md).
Narrows [ADR 0019](0019-cv-frontend-timoni-module-and-k8s-target.md)'s
"pitchfork container is retained" clause — it is not.
