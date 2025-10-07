# === WAHA Dockerfile — robust build with Yarn v3 fixes + ioredis stub ===
ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

#
# Build stage: install deps, force core-only build, prepare node_modules with stub
#
FROM node:${NODE_IMAGE_TAG} AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True

# Force core-only build flags for WAHA compilation
ENV WAHA_VERSION=core
ENV WAHA_CORE_ONLY=true
ENV WAHA_DISABLE_REDIS=true

WORKDIR /git

# copy package manifests first (cache-friendlier)
COPY package.json yarn.lock ./

# install system build tools needed for native modules
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl build-essential python3 python3-dev python3-pip make g++ pkg-config \
    libvips-dev ffmpeg libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Yarn setup (use Yarn Berry, node-modules linker)
RUN npm install -g corepack && corepack enable
RUN yarn set version 3.6.3
# Ensure Yarn uses node_modules (many projects expect node_modules layout)
RUN mkdir -p /git && \
    cat > /git/.yarnrc.yml <<'YARNRC' \
nodeLinker: "node-modules" \
YARNRC

# Install dependencies (Yarn v3 compatible; inline-builds for native build scripts)
RUN yarn install --frozen-lockfile --inline-builds --network-concurrency 4

# Replace any real ioredis in node_modules with a safe no-op stub (prevents network connects)
RUN rm -rf node_modules/ioredis || true \
 && mkdir -p node_modules/ioredis \
 && cat > node_modules/ioredis/index.js <<'JS' \
/**
 * ioredis stub to prevent network connections during runtime.
 */
module.exports = class Redis {
  constructor(){ this.isStub=true; }
  on(){ return this; }
  once(){ return this; }
  off(){ return this; }
  quit(cb){ if(typeof cb==='function') cb(null,'OK'); return Promise.resolve('OK'); }
  disconnect(){ return; }
  get(){ return Promise.resolve(null); }
  set(){ return Promise.resolve('OK'); }
  del(){ return Promise.resolve(0); }
  publish(){ return Promise.resolve(0); }
  subscribe(){ return; }
  unsubscribe(){ return; }
  multi(){ return this; }
  exec(){ return Promise.resolve([]); }
};
JS

# Copy the full source & install any build-time deps required by build scripts
COPY . /git
# ensure any workspace installs run if necessary
RUN yarn install --frozen-lockfile --inline-builds --network-concurrency 4

# Build WAHA (core-only)
RUN yarn build && find ./dist -name "*.d.ts" -delete

# Safety grep (prints occurrences if any ioredis left in built files; helpful for debugging)
RUN if grep -R --line-number "ioredis" ./dist 2>/dev/null | grep -q .; then \
      echo "WARNING: ioredis references found in dist:"; \
      grep -R --line-number "ioredis" ./dist || true; \
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
  if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
  mkdir -p /go/gows/bin && \
  wget -O /go/gows/bin/gows https://github.com/${GOWS_GITHUB_REPO}/releases/download/${GOWS_SHA}/gows-${ARCH} && \
  chmod +x /go/gows/bin/gows

#
# Final runtime image: copy prepared node_modules + dist (no redis client attempts)
#
FROM node:${NODE_IMAGE_TAG} AS release
ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV NODE_OPTIONS="--max-old-space-size=16384"
ARG USE_BROWSER=chromium
ARG WHATSAPP_DEFAULT_ENGINE

RUN echo "USE_BROWSER=$USE_BROWSER"

# Puppeteer / Chromium flags
ENV WA_PUPPETEER_HEADLESS=true
ENV WA_PUPPETEER_SANDBOX=false
ENV WA_PUPPETEER_SLOW_MO=50

# WAHA runtime safety flags
ENV WAHA_CORE_ONLY=true
ENV WAHA_REDIS_ENABLED=false
ENV WAHA_DISABLE_REDIS=true

# DB (sqlite)
ENV DB_TYPE=sqlite
ENV DB_SQLITE_FILENAME=/app/sessions.db

# Install runtime packages needed for headless chromium + ffmpeg (kept reasonably minimal)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg libvips zip unzip wget ca-certificates tini \
    xvfb xauth libc6 libnss3 libxss1 libasound2 libatk-bridge2.0-0 libgtk-3-0 libdrm2 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# copy prepared artifacts
COPY --from=build /git/node_modules ./node_modules
COPY --from=build /git/dist ./dist

# attach dashboard and GOWS
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

# Ensure entrypoint exists & is executable (copied from repo during build)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh || true

# Chokidar
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

# WAHA variables
ENV WAHA_ZIPPER=ZIPUNZIP

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]# Fonts
RUN if [ "$USE_BROWSER" = "chromium" ] || [ "$USE_BROWSER" = "chrome" ]; then \
    apt-get update && apt-get install -y \
        fontconfig fonts-freefont-ttf fonts-gfs-neohellenic fonts-indic \
        fonts-ipafont-gothic fonts-kacst fonts-liberation fonts-noto-cjk \
        fonts-noto-color-emoji fonts-roboto fonts-thai-tlwg fonts-wqy-zenhei \
        fonts-open-sans --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*; \
    fi

# xvfb, xauth
RUN if [ "$USE_BROWSER" = "chromium" ] || [ "$USE_BROWSER" = "chrome" ]; then \
    apt-get update && apt-get install -y --no-install-recommends \
        xvfb xauth libnss3 libxss1 libasound2 libatk-bridge2.0-0 \
        libgtk-3-0 libdrm2 ca-certificates \
    && rm -rf /var/lib/apt/lists/*; \
    fi

# Chromium
RUN if [ "$USE_BROWSER" = "chromium" ]; then \
    apt-get update && apt-get install -y chromium --no-install-recommends && rm -rf /var/lib/apt/lists/*; \
    fi

# Chrome
ARG CHROME_VERSION="140.0.7339.80-1"
RUN if [ "$USE_BROWSER" = "chrome" ]; then \
    wget --no-verbose -O /tmp/chrome.deb https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_${CHROME_VERSION}_amd64.deb \
    && apt-get update && apt install -y /tmp/chrome.deb \
    && rm /tmp/chrome.deb && rm -rf /var/lib/apt/lists/*; \
    fi

# curl, libc6, tini
RUN apt-get update && apt-get install -y curl libc6 tini && rm -rf /var/lib/apt/lists/*

ENV WHATSAPP_DEFAULT_ENGINE=$WHATSAPP_DEFAULT_ENGINE

WORKDIR /app
COPY package.json ./
COPY --from=build /git/node_modules ./node_modules
COPY --from=build /git/dist ./dist
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

# Chokidar
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

# WAHA
ENV WAHA_ZIPPER=ZIPUNZIP

# Replace ioredis with stub to avoid Redis errors
RUN find ./node_modules/ioredis -type f -exec sh -c 'echo "module.exports={};" > {}' \;

COPY entrypoint.sh /entrypoint.sh

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
