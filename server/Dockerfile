# Sonny gateway — a portable container image.
#
# **Portability is the whole point of this file** (decision doc §12.2, superseded in part by §12.4).
# The gateway's host changes across the product's life: beta runs on Oracle Cloud, v1 on AWS.
# **Nothing below couples to either of them** -- they are named in this comment because a reader
# should know why portability matters, and nowhere else: no host-specific stage, base image, flag or
# default appears in this file. What each host receives is an OCI image and a set of environment
# variables, which both of them can run, so moving is a redeploy rather than a rewrite.

# ── build ────────────────────────────────────────────────────────────────────
# Pinned to a minor rather than floating on `node:22`. Not pinned to a digest: a digest survives
# only until the base is rebuilt for a CVE, and with no CI to bump it a stale digest would quietly
# ship known-vulnerable bytes for months. The minor tag is the honest middle -- reproducible enough
# to reason about, still receiving patch rebuilds. Revisit if CI ever exists (row 20).
FROM node:22.20-bookworm-slim AS build
WORKDIR /app

# Dependencies first, so a source-only change does not reinstall them.
COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Reinstall production dependencies only, into a clean tree the runtime stage copies wholesale.
RUN npm ci --omit=dev

# ── runtime ──────────────────────────────────────────────────────────────────
FROM node:22.20-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production

# The build identifier GET /v1/health returns. Passed at build time so two deployments of the same
# source are distinguishable, which is the founder's own manual-test item for this ticket:
#   docker build --build-arg SONNY_BUILD_ID="$(git rev-parse --short HEAD)" .
ARG SONNY_BUILD_ID=unknown
ENV SONNY_BUILD_ID=${SONNY_BUILD_ID}

COPY --from=build /app/node_modules ./node_modules
# `dist` carries the compiled runner AND the .sql files beside it, because `npm run build` copies
# them -- tsc does not copy non-TypeScript assets. So `npm run migrate` works in this image exactly
# as it does locally: one invocation, both environments. It did not before. `src/` is absent from
# this stage while the old `migrate` script pointed at it, so the documented command could not run
# here at all, and the compiled runner that could had no .sql files beside it.
COPY --from=build /app/dist ./dist
COPY package.json ./

# Run as a non-root user. `node` exists in this base image already.
USER node

EXPOSE 8080
# No HEALTHCHECK instruction: /v1/health is for the platform's probe, and each host configures that
# its own way. Baking one in would express a preference in the one file that is supposed to be
# host-agnostic.
CMD ["node", "dist/server.js"]
