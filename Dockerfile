ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

#
# Build
#
FROM node:${NODE_IMAGE_TAG} AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True

# npm packages
WORKDIR /git
COPY package.json .
COPY yarn.lock .
ENV YARN_CHECKSUM_BEHAVIOR=update

# git
RUN apt-get update && apt-get install -y git

RUN npm install -g corepack && corepack enable
RUN yarn set version 3.6.3

# Install dependencies (Yarn v3 compliant)
RUN yarn install --frozen-lockfile

# App
WORKDIR /git
ADD . /git
RUN yarn install --frozen-lockfile
RUN yarn build && find ./dist -name "*.d.ts" -delete

#
# Dashboard
#
FROM node:${NODE_IMAGE_TAG} AS dashboard

# jq to parse json
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*

# wget, unzip
RUN apt-get update && apt-get install -y wget unzip && rm -rf /var/lib/apt/lists/*

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
# GOWS
#
FROM golang:${GOLANG_IMAGE_TAG} AS gows

# jq to parse json
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*

# install protoc
RUN apt-get update && apt-get install protobuf-compiler -y

# Image processing for thumbnails
RUN apt-get update && apt-get install -y libvips-dev && rm -rf /var/lib/apt/lists/*

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
# Final (Core image, Redis disabled)
#
FROM node:${NODE_IMAGE_TAG} AS release
ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV NODE_OPTIONS="--max-old-space-size=16384"
ARG USE_BROWSER=chromium
ARG WHATSAPP_DEFAULT_ENGINE

RUN echo "USE_BROWSER=$USE_BROWSER"

# Install ffmpeg
RUN apt-get update && apt-get install -y ffmpeg --no-install-recommends && rm -rf /var/lib/apt/lists/*

# Image processing
RUN apt-get update && apt-get install -y libvips && rm -rf /var/lib/apt/lists/*

# zip, unzip
RUN if [ "$USE_BROWSER" = "chromium" ] || [ "$USE_BROWSER" = "chrome" ]; then \
    apt-get update && apt-get install -y zip unzip && rm -rf /var/lib/apt/lists/*; \
    fi

# wget
RUN if [ "$USE_BROWSER" = "chromium" ] || [ "$USE_BROWSER" = "chrome" ]; then \
    apt-get update && apt-get install -y wget && rm -rf /var/lib/apt/lists/*; \
    fi

# Fonts
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
