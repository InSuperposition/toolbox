# The demo consumer is a local pitchfork-supervised container, not a k8s Deployment

The approved image runs as a standalone `pitchfork`-supervised Docker
container on the dev Mac (`[daemons.frontend]` →
`deploy/frontend/scripts/frontend-serve.sh`), not a Kubernetes Deployment.
`mise run frontend:deploy` verifies the pinned approval, records the image +
attestation digest in `current-image.txt` (git-ignored, atomic write), and
restarts the daemon; `frontend-serve.sh` re-verifies at launch.

Why: Tekton's k8s dependency is about the *build engine*, not a requirement
that the deployed app live in-cluster — the same separation the design
already applies to the approval step (which runs "outside Tekton
entirely"). Keeping the app out of the cluster keeps the cluster
architecture-agnostic (arm64-native, no amd64-image scheduling concerns)
and a single instance genuinely needs no orchestration. This is a
demo/proof of the pipeline mechanism, not where a real `cv_frontend` site
lives (that stays a separate decision — `TODOS.md`).

Status: accepted. Supersedes the earlier locked decision (a `cv-frontend`
k8s namespace + `kubectl apply` gated by `mise run consume`). **Amended by
[ADR 0019](0019-cv-frontend-timoni-module-and-k8s-target.md)** — the demo app
now *also* runs as a Kubernetes Deployment (Timoni + Flux); the pitchfork
container is retained as the path with full launch-time approval
re-verification.
