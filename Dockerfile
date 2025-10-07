# === COMPLETE WAHA DOCKERFILE (build core-only + stub ioredis) ===
ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

#
# Build
#
FROM node:${NODE_IMAGE_TAG} AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True

# Force WAHA core-only flags for build-time (so the produced dist is core)
ENV WAHA_VERSION=core
ENV WAHA_CORE_ONLY=true
ENV WAHA_DISABLE_REDIS=true

# npm packages
WORKDIR /git
COPY package.json .
COPY yarn.lock .
ENV YARN_CHECKSUM_BEHAVIOR=update

# install git (needed by some installs)
RUN apt-get update && apt-get install -y git ca-certificates && rm -rf /var/lib/apt/lists/*

RUN npm install -g corepack && corepack enable
RUN yarn set version 3.6.3

# Install dependencies (this will populate node_modules)
RUN yarn install --frozen-lockfile --production=false

# Replace any real ioredis with a no-op stub in node_modules (prevents any real Redis connection)
RUN rm -rf node_modules/ioredis \
 && mkdir -p node_modules/ioredis \
 && cat > node_modules/ioredis/index.js <<'JS'
/**
 * ioredis stub to prevent network connections during runtime.
 * Provides commonly used methods used by WAHA code but performs no I/O.
 */
module.exports = class Redis {
  constructor() { this.isStub = true; }
  on() { return this; }
  once() { return this; }
  off() { return this; }
  quit(cb) { if(typeof cb==='function') cb(null,'OK'); return Promise.resolve('OK'); }
  disconnect() { return; }
  get() { return Promise.resolve(null); }
  set() { return Promise.resolve('OK'); }
  del() { return Promise.resolve(0); }
  publish() { return Promise.resolve(0); }
  subscribe() { return; }
  unsubscribe() { return; }
  multi() { return this; }
  exec() { return Promise.resolve([]); }
};
JS

# Copy source and build (ensures build uses the stub and core flags)
WORKDIR /git
ADD . /git

# Reinstall dev deps if required by build scripts (safe)
RUN yarn install --frozen-lockfile

# Build WAHA
RUN yarn build && find ./dist -name "*.d.ts" -delete

# Safety check: confirm dist/node files do not contain direct ioredis strings
# (This will not fail the build, but will print occurrences if any)
RUN set -e; \
    if grep -R --line-number "ioredis" ./dist 2>/dev/null | grep -q .; then \
       echo "Warning: ioredis references found in dist:"; grep -R --line-number "ioredis" ./dist || true; \
    else echo "OK: no ioredis references in dist"; fi

#
# Dashboard stage (unchanged)
#
FROM node:${NODE_IMAGE_TAG} AS dashboard

RUN apt-get update && apt-get install -y jq wget unzip && rm -rf /var/lib/apt/lists/*

COPY waha.config.json /tmp/waha.config.json
RUN \
    WAHA_DASHBOARD_GITHUB_REPO=$(jq -r '.waha.dashboard.repo' /tmp/waha.config.json) && \
    WAHA_DASHBOARD_SHA=$(jq -r '.waha.dashboard.ref' /tmp/waha.config.json) && \
    wget https://github.com/${WAHA_DASHBOARD_GITHUB_REPO}/archive/${WAHA_DASHBOARD_SHA}.zip \
    && unzip ${WAHA_DASHBOARD_SHA}.zip -d /tmp/dashboard \
    && mkdir -p /dashboard \
    && mv /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}/* /dashboard/ \
    && rm -rf ${WAHA_DASHBOARD_SHA}.zip \
    && rm -rf /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}

#
# GOWS stage (unchanged)
#
FROM golang:${GOLANG_IMAGE_TAG} AS gows

RUN apt-get update && apt-get install -y jq protobuf-compiler libvips-dev && rm -rf /var/lib/apt/lists/*

COPY waha.config.json /tmp/waha.config.json
WORKDIR /go/gows
RUN \
    GOWS_GITHUB_REPO=$(jq -r '.waha.gows.repo' /tmp/waha.config.json) && \
    GOWS_SHA=$(jq -r '.waha.gows.ref' /tmp/waha.config.json) && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    mkdir -p /go/gows/bin && \
    wget -O /go/gows/bin/gows https://github.com/${GOWS_GITHUB_REPO}/releases/download/${GOWS_SHA}/gows-${ARCH} && \
    chmod +x /go/gows/bin/gows

#
# Final runtime image (node) - copy prepared node_modules + dist
#
FROM node:${NODE_IMAGE_TAG} AS release
ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV NODE_OPTIONS="--max-old-space-size=16384"
ARG USE_BROWSER=chromium
ARG WHATSAPP_DEFAULT_ENGINE

RUN echo "USE_BROWSER=$USE_BROWSER"

# Puppeteer / Chromium flags (keep your previous choices)
ENV WA_PUPPETEER_HEADLESS=true
ENV WA_PUPPETEER_SANDBOX=false
ENV WA_PUPPETEER_SLOW_MO=50

# WAHA runtime (safety)
ENV WAHA_CORE_ONLY=true
ENV WAHA_REDIS_ENABLED=false
ENV WAHA_DISABLE_REDIS=true

# DB (sqlite)
ENV DB_TYPE=sqlite
ENV DB_SQLITE_FILENAME=/app/sessions.db

# System packages needed for runtime browser support
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ffmpeg libvips zip unzip wget ca-certificates tini \
    xvfb xauth libnss3 libxss1 libasound2 libatk-bridge2.0-0 libgtk-3-0 libdrm2 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# copy prepared node_modules and dist from build
COPY --from=build /git/node_modules ./node_modules
COPY --from=build /git/dist ./dist

# attach dashboard and GOWS binaries
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

# Ensure entrypoint exists if you have one in repo; else use base behavior
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh || true

# Chokidar options
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

# WAHA variables
ENV WAHA_ZIPPER=ZIPUNZIP

# final port and entrypoint
EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]WORKDIR /app
COPY --from=gows /go/gows/bin/gows /app/gows
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

# Attach Dashboard
COPY --from=dashboard /dashboard ./dist/dashboard

# --- Redis stub: prevent any real ioredis from connecting ---
RUN mkdir -p /app/node_modules/ioredis \
 && cat > /app/node_modules/ioredis/index.js <<'JS'
module.exports = class Redis {
  constructor() { this.isStub = true; }
  on() { return this; }
  once() { return this; }
  off() { return this; }
  quit(cb) { if(typeof cb==='function') cb(null,'OK'); return Promise.resolve('OK'); }
  disconnect() { return; }
  get() { return Promise.resolve(null); }
  set() { return Promise.resolve('OK'); }
  del() { return Promise.resolve(0); }
  publish() { return Promise.resolve(0); }
  subscribe() { return; }
  unsubscribe() { return; }
  multi() { return this; }
  exec() { return Promise.resolve([]); }
};
JS

# ------------------ NEW: ensure entrypoint exists & git is available ------------------
# Copy the project's entrypoint script into the final image (if present in repo)
# and make it executable. Some WAHA entrypoints expect git; install git to avoid fatal 128.
# If you already have an entrypoint in the base image, this copy will overwrite it with your repo one.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
 && apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*

# Chokidar options to monitor file changes
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

# WAHA variables
ENV WAHA_ZIPPER=ZIPUNZIP

# Expose port
EXPOSE 3000

# Entrypoint
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]WORKDIR /app
COPY --from=gows /go/gows/bin/gows /app/gows
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

# Attach Dashboard
COPY --from=dashboard /dashboard ./dist/dashboard

# --- Redis stub: prevent any real ioredis from connecting ---
RUN mkdir -p /app/node_modules/ioredis \
 && cat > /app/node_modules/ioredis/index.js <<'JS'
module.exports = class Redis {
  constructor() { this.isStub = true; }
  on() { return this; }
  once() { return this; }
  off() { return this; }
  quit(cb) { if(typeof cb==='function') cb(null,'OK'); return Promise.resolve('OK'); }
  disconnect() { return; }
  get() { return Promise.resolve(null); }
  set() { return Promise.resolve('OK'); }
  del() { return Promise.resolve(0); }
  publish() { return Promise.resolve(0); }
  subscribe() { return; }
  unsubscribe() { return; }
  multi() { return this; }
  exec() { return Promise.resolve([]); }
};
JS

# Chokidar options to monitor file changes
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

# WAHA variables
ENV WAHA_ZIPPER=ZIPUNZIP

# Expose port
EXPOSE 3000

# Entrypoint
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]WORKDIR /app
COPY --from=gows /go/gows/bin/gows /app/gows
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

COPY --from=dashboard /dashboard ./dist/dashboard

# Chokidar options to monitor file changes
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

# WAHA variables
ENV WAHA_ZIPPER=ZIPUNZIP

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]WORKDIR /app
COPY --from=gows /go/gows/bin/gows /app/gows
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

COPY --from=dashboard /dashboard ./dist/dashboard

# Chokidar options to monitor file changes
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

# WAHA variables
ENV WAHA_ZIPPER=ZIPUNZIP

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
