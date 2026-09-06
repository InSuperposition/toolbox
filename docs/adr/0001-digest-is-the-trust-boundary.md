# Digest is the enforced trust boundary

Every consumed artifact is pinned by content digest — a git commit SHA for
git-sourced OpenTofu modules (`?ref=<sha>`, never `?ref=v1.2.0`), a sha256
for OCI artifacts — and `mise.toml` pins every tool to a concrete version,
never `latest`. Human-friendly tags are convenience aliases layered on top
once signing exists, never the boundary itself.

Why: mutable tags are a live supply-chain risk class (the zendesk/changed-files
tag-retargeting incident, CVE-2026-33634), and "tag for discovery, deploy by
digest" is the accepted GitOps/OCI pattern. The repo's stated zero-trust
goal is not met while modules resolve by branch/tag and tools resolve by
`latest`.
