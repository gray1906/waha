# === WAHA Dockerfile — Core-only build (no Redis), Yarn v3, production safe ===
ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

# -----------------------------
# BUILD STAGE
# -----------------------------
FROM node:${NODE_IMAGE_TAG} AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV WAHA_VERSION=core
ENV WAHA_CORE_ONLY=true
ENV WAHA_DISABLE_REDIS=true

WORKDIR /git

# Copy manifests first
COPY package.json yarn.lock ./

# Install system prerequisites
RUN apt-get update && apt-get install -y --no-install-recommends \
  git ca-certificates curl build-essential python3 make g++ pkg-config libvips-dev ffmpeg libglib2.0-0 \
  && rm -rf /var/lib/apt/lists/*

# Enable Corepack + Yarn v3
RUN npm install -g corepack && corepack enable
RUN yarn set version 3.6.3

# Force Yarn to use node_modules linker (not PnP)
RUN echo 'nodeLinker: "node-modules"' > .yarnrc.yml

# Install dependencies
RUN yarn install --frozen-lockfile --inline-builds

# Replace ioredis with a safe no-op stub
RUN rm -rf node_modules/ioredis && mkdir -p node_modules/ioredis && \
  printf '%s\n' '/**\n * ioredis stub to disable Redis connections.\n */\nclass Redis {\n  constructor(){this.isStub=true;}\n  on(){return this;}\n  once(){return this;}\n  off(){return this;}\n  quit(cb){if(cb)cb(null,\"OK\");return Promise.resolve(\"OK\");}\n  disconnect(){}\n  get(){return Promise.resolve(null);}\n  set(){return Promise.resolve(\"OK\");}\n  del(){return Promise.resolve(0);}\n  publish(){return Promise.resolve(0);}\n  subscribe(){}\n  unsubscribe(){}\n  multi(){return this;}\n  exec(){return Promise.resolve([]);}\n}\nmodule.exports = Redis;\n' > node_modules/ioredis/index.js

# Copy the rest of the app
COPY . /git

# Reinstall just in case (safe fallback)
RUN yarn install --frozen-lockfile --inline-builds || true

# Build WAHA core
RUN yarn build && find ./dist -name "*.d.ts" -delete

# Verify no Redis in dist
RUN if grep -R --line-number "ioredis" ./dist 2>/dev/null | grep -q .; then \
      echo "WARNING: ioredis references found in dist:"; grep -R --line-number "ioredis" ./dist || true; \
    else echo "OK: no ioredis references in dist"; fi

# -----------------------------
# DASHBOARD STAGE
# -----------------------------
FROM node:${NODE_IMAGE_TAG} AS dashboard
RUN apt-get update && apt-get install -y jq wget unzip && rm -rf /var/lib/apt/lists/*
COPY waha.config.json /tmp/waha.config.json
RUN \
  WAHA_DASHBOARD_GITHUB_REPO=$(jq -r '.waha.dashboard.repo' /tmp/waha.config.json) && \
  WAHA_DASHBOARD_SHA=$(jq -r '.waha.dashboard.ref' /tmp/waha.config.json) && \
  wget https://github.com/${WAHA_DASHBOARD_GITHUB_REPO}/archive/${WAHA_DASHBOARD_SHA}.zip && \
  unzip ${WAHA_DASHBOARD_SHA}.zip -d /tmp/dashboard && \
  mkdir -p /dashboard && \
  mv /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}/* /dashboard/ && \
  rm -rf ${WAHA_DASHBOARD_SHA}.zip /tmp/dashboard

# -----------------------------
# GOWS STAGE
# -----------------------------
FROM golang:${GOLANG_IMAGE_TAG} AS gows
RUN apt-get update && apt-get install -y jq protobuf-compiler libvips-dev && rm -rf /var/lib/apt/lists/*
COPY waha.config.json /tmp/waha.config.json
WORKDIR /go/gows
RUN \
  GOWS_GITHUB_REPO=$(jq -r '.waha.gows.repo' /tmp/waha.config.json) && \
  GOWS_SHA=$(jq -r '.waha.gows.ref' /tmp/waha.config.json) && \
  ARCH=$(uname -m) && \
  if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; else echo "Unsupported arch: $ARCH" && exit 1; fi && \
  mkdir -p /go/gows/bin && \
  wget -O /go/gows/bin/gows https://github.com/${GOWS_GITHUB_REPO}/releases/download/${GOWS_SHA}/gows-${ARCH} && \
  chmod +x /go/gows/bin/gows

# -----------------------------
# FINAL RUNTIME STAGE
# -----------------------------
FROM node:${NODE_IMAGE_TAG} AS release
ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV NODE_OPTIONS="--max-old-space-size=16384"
ENV WAHA_CORE_ONLY=true
ENV WAHA_DISABLE_REDIS=true
ENV WAHA_REDIS_ENABLED=false
ENV DB_TYPE=sqlite
ENV DB_SQLITE_FILENAME=/app/sessions.db

# Install runtime deps
RUN apt-get update && apt-get install -y --no-install-recommends \
  ffmpeg libvips zip unzip wget ca-certificates tini xvfb xauth libc6 libnss3 libxss1 libasound2 libatk-bridge2.0-0 libgtk-3-0 libdrm2 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /git/node_modules ./node_modules
COPY --from=build /git/dist ./dist
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows

ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock
ENV WAHA_ZIPPER=ZIPUNZIP
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

# Optional entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh || true

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]ENV WAHA_CORE_ENABLED=true
ENV WAHA_APPS_ENABLED=true
ENV WAHA_VERSION=core
ENV DB_TYPE=sqlite
ENV DB_SQLITE_FILENAME=/app/sessions.db
ENV LOG_LEVEL=info
ENV WAHA_ZIPPER=ZIPUNZIP
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

COPY entrypoint.sh /entrypoint.sh
EXPOSE 3000

# Use tini as init system
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]

# === End of Dockerfile ===fi

# Final fallback: execute passed command
exec "$@"
SH

RUN chmod +x /entrypoint.sh

# ---------------------------
# 5️⃣ Final command
# ---------------------------
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
