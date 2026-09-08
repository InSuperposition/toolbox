# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
#
# Packages the external consumer `cv_frontend` as a distroless Node image.
#
# This is the ONE hand-authored Dockerfile in toolbox -- see CLAUDE.md
# "No code inside configuration files" for the named carve-out and its
# reasoning. It is deliberately a minimal two-stage build (two RUN lines,
# no shell logic), not the "RUN soup" that rule targets. Design:
# docs/designs/digest-as-source-of-truth.md, section "Pivot (2026-09-06)".
#
# Build context is a cv_frontend checkout:
#   docker buildx build -f deploy/frontend/Dockerfile --platform linux/arm64 \
#     --push --metadata-file meta.json ./cv_frontend
#
# Both base images are pinned by digest -- this design's own digest-over-tag
# thesis applied to its build inputs, not just what it builds.

# ---- Stage 1: install production dependencies ---------------------------
# Full Node image (has npm) resolves cv_frontend's single prod dep `remix`
# and runs its allowScripts postinstall (the esbuild native binary). Runs
# natively on the build platform's arch -- the workflow uses an arm64
# runner so this is arm64, no QEMU, correct esbuild binary.
FROM node:26-trixie-slim@sha256:c0753125a3789977aefe869cbebccf70e3cfd7ea84ca48547458f02e4f1d7146 AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---- Stage 2: distroless runtime --------------------------------------
# No shell, no package manager, runs as nonroot (uid 65532). Entrypoint is
# already ["node"]; CMD supplies the args. cv_frontend runs TypeScript at
# runtime via the remix/node-tsx loader -- no compile step exists.
FROM gcr.io/distroless/nodejs26-debian13:nonroot@sha256:10ec8cb93ef461563da50d4eb8dfac7d048783826825bf5b07510c2f34c14315 AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    PORT=44100 \
    XDG_CACHE_HOME=/tmp
COPY --from=deps /app/node_modules ./node_modules
COPY package.json tsconfig.json server.ts ./
COPY app ./app
COPY public ./public
EXPOSE 44100
CMD ["--import", "remix/node-tsx", "server.ts"]
