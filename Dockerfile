# === ARGs ===
ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

#
# ==============================
# 1️⃣ Build Stage
# ==============================
FROM node:${NODE_IMAGE_TAG} AS build

WORKDIR /app

# Enable Corepack and set Yarn to exact version
RUN npm install -g corepack && corepack enable
RUN corepack prepare yarn@3.6.3 --activate

# Copy package files first
COPY package.json yarn.lock ./

# Install dependencies safely (Yarn v3)
RUN yarn install --immutable

# Copy app source
COPY . .

# Build the WAHA app
RUN yarn build && find ./dist -name "*.d.ts" -delete

#
# ==============================
# 2️⃣ Dashboard Stage
# ==============================
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
    rm -rf ${WAHA_DASHBOARD_SHA}.zip /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}

#
# ==============================
# 3️⃣ GOWS Stage
# ==============================
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
# ==============================
# 4️⃣ Release Stage (Final)
# ==============================
FROM node:${NODE_IMAGE_TAG} AS release

ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV NODE_OPTIONS="--max-old-space-size=16384"
ARG USE_BROWSER=chromium
ARG WHATSAPP_DEFAULT_ENGINE

RUN echo "USE_BROWSER=$USE_BROWSER"

# Install system dependencies
RUN apt-get update && apt-get install -y ffmpeg libvips zip unzip wget curl libc6 tini \
    xvfb xauth libnss3 libxss1 libasound2 libatk-bridge2.0-0 libgtk-3-0 libdrm2 ca-certificates \
    fonts-freefont-ttf fonts-gfs-neohellenic fonts-indic fonts-ipafont-gothic fonts-kacst \
    fonts-liberation fonts-noto-cjk fonts-noto-color-emoji fonts-roboto fonts-thai-tlwg \
    fonts-wqy-zenhei fonts-open-sans fontconfig \
    && rm -rf /var/lib/apt/lists/*

# Optional Chromium installation
RUN if [ "$USE_BROWSER" = "chromium" ]; then \
        apt-get update && apt-get install -y chromium && rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /app

# Copy node_modules and built app from build stage
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows

# WAHA GOWS paths
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

# Environment variables to completely disable Redis
ENV WAHA_REDIS_ENABLED=false
ENV WAHA_DISABLE_REDIS=true
ENV WAHA_CORE_ENABLED=true
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
