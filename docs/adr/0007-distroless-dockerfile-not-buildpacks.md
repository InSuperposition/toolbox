# cv_frontend is built as a distroless Node image from a hand-authored Dockerfile

`deploy/frontend/Dockerfile` is a minimal two-stage build — `node:26`
builder → `gcr.io/distroless/nodejs26-debian13` runtime, both pinned by
digest, two `RUN` lines, no shell logic. Phase-1 CI uses `docker buildx`;
Phase-2 Tekton uses an in-cluster daemonless builder (undecided — see
`TODOS.md`).

Why: Paketo buildpacks pulled a ~1 GB builder image every CI run and
carried two CVEs that only existed in the Paketo toolchain
(`golang.org/x/crypto` in an `exec.d` helper, `node-tar` in Node 24.19.0's
bundled npm). Distroless ships no npm, no shell, no package manager — both
CVEs die at the root, not by `.trivyignore` suppression, and the runtime
attack surface shrinks to libc + Node. A two-`RUN` multi-stage Dockerfile
is the industry-standard declarative form, not the "RUN soup" the
no-code-in-config rule targets — hence the named CLAUDE.md carve-out.

Considered and rejected: apko/melange (fully declarative, no Dockerfile) —
an innovation-token overspend for packaging one npm app.

Status: accepted. Supersedes the original Paketo buildpacks approach
(`builder-jammy-base`, itself chosen after `builder-jammy-tiny` was proven
to have no Node.js buildpack at all).
