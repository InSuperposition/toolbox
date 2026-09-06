# The image is linux/arm64 only

The build produces a single `linux/arm64` OCI manifest, not a multi-arch
index. Every consumer in this design is arm64 — the dev Mac, OrbStack's
cluster, the T5b local container. The GitHub Actions build runs on a native
`ubuntu-24.04-arm` runner (no QEMU).

Why: the earlier amd64 constraint was a Paketo limitation (its Jammy
builders are amd64-only). Distroless is multi-arch, so arm64-native is now
possible and simpler. Multi-arch would turn the approved artifact into an
*index* digest, forcing the approve/consume path to scan and smoke-test
both child manifests — real cost for no current benefit.

Status: accepted. Supersedes the amd64 constraint. Multi-arch is deferred
to a real amd64 consumer — `TODOS.md` "Publish a multi-arch image once a
real amd64 consumer exists".
