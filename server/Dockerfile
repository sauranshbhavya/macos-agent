# Sonny gateway — a portable container image.
#
# **Portability is the whole point of this file** (decision doc §12.2). The gateway's host changes
# across the product's life: development first tries deploymind, beta runs on Oracle Cloud, v1 on
# AWS. Nothing below names any of them. What each host receives is an OCI image and a set of
# environment variables, which every one of them can run, so moving is a redeploy rather than a
# rewrite.

# ── build ────────────────────────────────────────────────────────────────────
FROM node:22-bookworm-slim AS build
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
FROM node:22-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production

# The build identifier GET /v1/health returns. Passed at build time so two deployments of the same
# source are distinguishable, which is the founder's own manual-test item for this ticket:
#   docker build --build-arg SONNY_BUILD_ID="$(git rev-parse --short HEAD)" .
ARG SONNY_BUILD_ID=unknown
ENV SONNY_BUILD_ID=${SONNY_BUILD_ID}

COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
# Migrations are read at runtime by `npm run migrate`, so they ship in the image rather than being
# fetched from a checkout the host may not have.
COPY --from=build /app/src/db/migrations ./dist/db/migrations
COPY package.json ./

# Run as a non-root user. `node` exists in this base image already.
USER node

EXPOSE 8080
# No HEALTHCHECK instruction: /v1/health is for the platform's probe, and each of the three hosts
# configures that its own way. Baking one in would express a preference in the one file that is
# supposed to be host-agnostic.
CMD ["node", "dist/server.js"]
