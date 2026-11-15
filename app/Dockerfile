# syntax=docker/dockerfile:1

# Pinned Node.js LTS base image. Pinning the digest as well as the tag would be
# stricter, but the tag is bumped deliberately for base-image updates.
ARG NODE_VERSION=24.14.1

# -----------------------------------------------------------------------------
# deps: production dependencies only.
# `npm ci` installs strictly from the lockfile so the image is reproducible.
# -----------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS deps

WORKDIR /app

COPY package.json package-lock.json ./

# --ignore-scripts blocks dependency lifecycle scripts from running arbitrary
# code at build time. Nothing in this dependency tree needs them.
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

# -----------------------------------------------------------------------------
# test: identical lockfile, test sources included. CI builds this target so the
# tests run in an environment that matches the runtime image's toolchain.
# Not part of the final image.
# -----------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS test

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

COPY src ./src
COPY tests ./tests

ENV NODE_ENV=test

CMD ["npm", "test"]

# -----------------------------------------------------------------------------
# runtime: minimal image, non-root, only what the process needs.
# -----------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS runtime

# Apply Alpine security updates at build time.
#
# The pinned base image ships OS packages older than the current Alpine
# security fixes: the first real Trivy run found 7 HIGH/CRITICAL findings, all
# in the base OS and none in our Node dependencies. Without this the security
# gate blocks deployment on packages the application does not even use.
#
# Trade-off, stated deliberately: this makes the image no longer byte-for-byte
# reproducible, because two builds on different days can resolve different
# package versions. A stricter alternative is to pin the base image by digest
# and rebuild on a schedule; that moves the problem rather than solving it, so
# the upgrade is applied here and the digest pin is left for production.
RUN apk upgrade --no-cache

# Remove the package manager from the runtime image.
#
# npm ships its own dependency tree (~17 MB, including tar 7.5.9). None of it
# can execute here: the container runs `node src/server.js` and installs nothing
# at runtime. Trivy scans the whole filesystem, so leaving npm in place means
# shipping - and being blocked by - vulnerable code the application cannot reach.
#
# This was previously dismissed as a size optimisation ("17 MB, not worth it").
# Size was the wrong argument. Attack surface is the right one.
RUN rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm \
           /usr/local/bin/npx \
           /usr/local/bin/corepack

# Defaults only. Real values are supplied by the ECS task definition so the same
# image runs unchanged in every environment.
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000

WORKDIR /app

COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src

# The official image ships an unprivileged `node` user (UID 1000). Never run the
# application as root.
USER node

EXPOSE 3000

# Local `docker run` health signal. Amazon ECS ignores Docker HEALTHCHECK; the
# ECS task definition defines its own container health check, and the ALB has a
# target group health check. Uses Node's built-in fetch so no curl/wget is
# installed purely for health checks.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 3000) + '/health').then((r) => process.exit(r.status === 200 ? 0 : 1)).catch(() => process.exit(1))"

# Exec form so the Node process is PID 1 and receives SIGTERM directly for the
# graceful shutdown path in src/server.js.
CMD ["node", "src/server.js"]
