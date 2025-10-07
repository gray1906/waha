ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

FROM node:${NODE_IMAGE_TAG} AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV WAHA_VERSION=core
ENV WAHA_CORE_ONLY=true
ENV WAHA_DISABLE_REDIS=true

WORKDIR /git

COPY package.json yarn.lock ./

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl build-essential python3 python3-dev python3-pip make g++ pkg-config \
    libvips-dev ffmpeg libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g corepack && corepack enable
RUN yarn set version 3.6.3
RUN printf '%s\n' 'nodeLinker: "node-modules"' > /git/.yarnrc.yml
RUN yarn install --frozen-lockfile --inline-builds

RUN rm -rf node_modules/ioredis node_modules/redis node_modules/@node-redis && \
    mkdir -p node_modules/ioredis node_modules/redis node_modules/@node-redis

RUN cat > node_modules/ioredis/index.js <<'JS'
// ioredis stub code
JS

RUN mkdir -p node_modules/ioredis/built && \
    cat > node_modules/ioredis/built/utils.js <<'JS'
// utils stub code
JS

RUN cat > node_modules/redis/index.js <<'JS'
// redis stub code
JS

RUN mkdir -p node_modules/@node-redis/client && \
    cat > node_modules/@node-redis/client/index.js <<'JS'
// @node-redis/client stub code
JS

RUN mkdir -p node_modules/@liaoliaots/nestjs-redis && \
    cat > node_modules/@liaoliaots/nestjs-redis/dist/index.js <<'JS'
// nestjs-redis stub code
JS

RUN mkdir -p node_modules/@waha/core/dist/common/rmutex && \
    cat > node_modules/@waha/core/dist/common/rmutex/index.js <<'JS'
// RMutexService stub with RedisClient provider
JS

COPY . /git
RUN yarn install --frozen-lockfile --inline-builds || true
RUN yarn build && find ./dist -name "*.d.ts" -delete

RUN echo "=== Checking for problematic Redis references ===" && \
    if find ./dist -name "*.js" -exec grep -l "ioredis\|@liaoliaots/nestjs-redis\|redis" {} \; 2>/dev/null | grep -q .; then \
        echo "WARNING: Redis references found in dist:"; \
        find ./dist -name "*.js" -exec grep -l "ioredis\|@liaoliaots/nestjs-redis\|redis" {} \; 2>/dev/null | while read file; do \
            echo "File: $file"; \
            grep -n "ioredis\|@liaoliaots/nestjs-redis\|redis" "$file" | head -5; \
        done; \
    else \
        echo "OK: no problematic Redis references in dist"; \
    fi

FROM node:${NODE_IMAGE_TAG} AS dashboard
RUN apt-get update && apt-get install -y jq wget unzip && rm -rf /var/lib/apt/lists/*
COPY waha.config.json /tmp/waha.config.json
RUN WAHA_DASHBOARD_GITHUB_REPO=$(jq -r '.waha.dashboard.repo' /tmp/waha.config.json) && \
    WAHA_DASHBOARD_SHA=$(jq -r '.waha.dashboard.ref' /tmp/waha.config.json) && \
    wget https://github.com/${WAHA_DASHBOARD_GITHUB_REPO}/archive/${WAHA_DASHBOARD_SHA}.zip && \
    unzip ${WAHA_DASHBOARD_SHA}.zip -d /tmp/dashboard && \
    mkdir -p /dashboard && \
    mv /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}/* /dashboard/ && \
    rm -rf ${WAHA_DASHBOARD_SHA}.zip && \
    rm -rf /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}

FROM golang:${GOLANG_IMAGE_TAG} AS gows
RUN apt-get update && apt-get install -y jq protobuf-compiler libvips-dev && rm -rf /var/lib/apt/lists/*
COPY waha.config.json /tmp/waha.config.json
WORKDIR /go/gows
RUN GOWS_GITHUB_REPO=$(jq -r '.waha.gows.repo' /tmp/waha.config.json) && \
    GOWS_SHA=$(jq -r '.waha.gows.ref' /tmp/waha.config.json) && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    mkdir -p /go/gows/bin && \
    wget -O /go/gows/bin/gows https://github.com/${GOWS_GITHUB_REPO}/releases/download/${GOWS_SHA}/gows-${ARCH} && \
    chmod +x /go/gows/bin/gows

FROM node:${NODE_IMAGE_TAG} AS release
ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV NODE_OPTIONS="--max-old-space-size=16384"
ARG USE_BROWSER=chromium
ARG WHATSAPP_DEFAULT_ENGINE
RUN echo "USE_BROWSER=$USE_BROWSER"

ENV WA_PUPPETEER_HEADLESS=true
ENV WA_PUPPETEER_SANDBOX=false
ENV WA_PUPPETEER_SLOW_MO=50

ENV WAHA_CORE_ONLY=true
ENV WAHA_REDIS_ENABLED=false
ENV WAHA_DISABLE_REDIS=true

ENV DB_TYPE=sqlite
ENV DB_SQLITE_FILENAME=/app/sessions.db

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg libvips zip unzip wget ca-certificates tini \
    xvfb xauth libc6 libnss3 libxss1 libasound2 libatk-bridge2.0-0 libgtk-3-0 libdrm2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /git/node_modules ./node_modules
COPY --from=build /git/dist ./dist
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows

ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh || true

ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000
ENV WAHA_ZIPPER=ZIPUNZIP

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
