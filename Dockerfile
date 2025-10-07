ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

# Build stage: prepare node_modules (with ioredis stub) and build core-only dist
FROM node:${NODE_IMAGE_TAG} AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True

# Force core-only flags for WAHA build-time
ENV WAHA_VERSION=core
ENV WAHA_CORE_ONLY=true
ENV WAHA_DISABLE_REDIS=true

WORKDIR /git

# Copy manifests first (cache friendly)
COPY package.json yarn.lock ./

# Install system prerequisites for building native modules
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl build-essential python3 python3-dev python3-pip make g++ pkg-config \
    libvips-dev ffmpeg libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Yarn setup (corepack + pinned Yarn Berry)
RUN npm install -g corepack && corepack enable
RUN yarn set version 3.6.3

# Ensure Yarn uses node_modules (avoid PnP surprises)
RUN printf '%s\n' 'nodeLinker: "node-modules"' > /git/.yarnrc.yml

# Install dependencies (Yarn v3 compatible). inline-builds allows native build scripts to run.
RUN yarn install --frozen-lockfile --inline-builds

# COMPREHENSIVE REDIS STUBBING - Replace ioredis and related Redis dependencies with stubs
RUN rm -rf node_modules/ioredis node_modules/redis node_modules/@node-redis && \
    mkdir -p node_modules/ioredis node_modules/redis node_modules/@node-redis

# Create comprehensive ioredis stub
RUN cat > node_modules/ioredis/index.js <<'JS'
class Redis {
  constructor(options) { this.options = options; this.status = 'close'; this.isStub = true; }
  connect() { return Promise.resolve(this); }
  disconnect() { this.status='close'; return this; }
  quit() { this.status='close'; return Promise.resolve('OK'); }
  on() { return this; }
  once() { return this; }
  off() { return this; }
  removeListener() { return this; }
  removeAllListeners() { return this; }
  get() { return Promise.resolve(null); }
  set() { return Promise.resolve('OK'); }
  del() { return Promise.resolve(0); }
  exists() { return Promise.resolve(0); }
  expire() { return Promise.resolve(0); }
  hget() { return Promise.resolve(null); }
  hset() { return Promise.resolve(0); }
  hgetall() { return Promise.resolve({}); }
  lpush() { return Promise.resolve(0); }
  rpush() { return Promise.resolve(0); }
  lpop() { return Promise.resolve(null); }
  rpop() { return Promise.resolve(null); }
  sadd() { return Promise.resolve(0); }
  smembers() { return Promise.resolve([]); }
  publish() { return Promise.resolve(0); }
  subscribe(channel) { return Promise.resolve([channel,0]); }
  unsubscribe(channel) { return Promise.resolve([channel,0]); }
  multi() { const m = new RedisMulti(); m.exec=()=>Promise.resolve([]); return m; }
  pipeline() { return this.multi(); }
  ping() { return Promise.resolve('PONG'); }
  time() { return Promise.resolve([Math.floor(Date.now()/1000),0]); }
  info() { return Promise.resolve(''); }
  scan() { return Promise.resolve(['0',[]]); }
}
class RedisMulti {
  constructor() { this._queue=[]; }
  get(key){this._queue.push(['get',key]); return this;}
  set(key,value){this._queue.push(['set',key,value]); return this;}
  del(...keys){this._queue.push(['del',...keys]); return this;}
  hset(key,field,value){this._queue.push(['hset',key,field,value]); return this;}
  exec(){return Promise.resolve([]);}
}
module.exports=Redis;
module.exports.Redis=Redis;
module.exports.Cluster=Redis;
module.exports.Command=class Command{};
module.exports.ReplyError=class ReplyError extends Error{};
JS

# 🧩 Add stub for ioredis/built/utils (required by BullMQ)
RUN mkdir -p node_modules/ioredis/built && \
    cat > node_modules/ioredis/built/utils.js <<'JS'
module.exports = {
  parseURL: () => ({}),
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms || 0)),
};
JS

# Create stubs for other Redis client packages
RUN cat > node_modules/redis/index.js <<'JS'
module.exports = {
  createClient: () => ({
    connect: () => Promise.resolve(),
    on: () => {},
    quit: () => Promise.resolve(),
    get: () => Promise.resolve(null),
    set: () => Promise.resolve('OK'),
    isOpen: true
  })
};
JS

RUN mkdir -p node_modules/@node-redis/client && \
    cat > node_modules/@node-redis/client/index.js <<'JS'
module.exports = {
  createClient: () => ({
    connect: () => Promise.resolve(),
    on: () => {},
    quit: () => Promise.resolve(),
    get: () => Promise.resolve(null),
    set: () => Promise.resolve('OK')
  })
};
JS

# Stub the NestJS Redis module itself
RUN mkdir -p node_modules/@liaoliaots/nestjs-redis && \
    cat > node_modules/@liaoliaots/nestjs-redis/dist/index.js <<'JS'
exports.RedisModule={forRoot:()=>({module:class RedisModuleStub{}}),forRootAsync:()=>({module:class RedisModuleStubAsync{}})};
exports.RedisService=class RedisServiceStub{};
exports.InjectRedis=()=>()=>{};
JS

# 🧩 CRITICAL: Stub RMutexService at SOURCE level BEFORE building
# This ensures the real source code is replaced before compilation
RUN mkdir -p node_modules/@waha/core/src/common/rmutex && \
    cat > node_modules/@waha/core/src/common/rmutex/index.ts <<'TS'
export class RMutexService {
  constructor(
    private readonly options: any,
    private readonly logger: any, 
    private readonly ttl: number
  ) {
    console.log('RMutexService STUB: Distributed locking disabled');
  }

  async acquireLock(resource: string): Promise<boolean> {
    console.log('RMutexService STUB: acquireLock for', resource);
    return true;
  }

  async releaseLock(resource: string): Promise<boolean> {
    console.log('RMutexService STUB: releaseLock for', resource);
    return true;
  }

  async withLock<T>(resource: string, fn: () => Promise<T>): Promise<T> {
    console.log('RMutexService STUB: withLock for', resource, '- executing without lock');
    return await fn();
  }
}

export const RMutexModule = {
  forRoot: () => ({
    module: class RMutexModule {},
    providers: [
      {
        provide: RMutexService,
        useFactory: (options: any, logger: any, ttl: number) => {
          return new RMutexService(options, logger, ttl);
        },
        inject: ['RMUTEX_OPTIONS', 'PinoLogger:RMutexService', 'RMUTEX_DEFAULT_TTL']
      }
    ],
    exports: [RMutexService]
  }),
  forRootAsync: () => ({
    module: class RMutexModuleAsync {},
    providers: [
      {
        provide: RMutexService,
        useFactory: (options: any, logger: any, ttl: number) => {
          return new RMutexService(options, logger, ttl);
        },
        inject: ['RMUTEX_OPTIONS', 'PinoLogger:RMutexService', 'RMUTEX_DEFAULT_TTL']
      }
    ],
    exports: [RMutexService]
  }),
};
TS

# Also create a pre-compiled version as backup
RUN mkdir -p node_modules/@waha/core/dist/common/rmutex && \
    cat > node_modules/@waha/core/dist/common/rmutex/index.js <<'JS'
class RMutexService {
  constructor(options, logger, ttl) { 
    this.options=options; 
    this.logger=logger; 
    this.ttl=ttl; 
    console.log('RMutexService STUB: Distributed locking disabled'); 
  }
  async acquireLock(resource){console.log('RMutexService STUB: acquireLock for',resource); return true;}
  async releaseLock(resource){console.log('RMutexService STUB: releaseLock for',resource); return true;}
  async withLock(resource,fn){console.log('RMutexService STUB: withLock for',resource,'- executing without lock'); return await fn();}
}
const RMutexModule={
  forRoot:()=>({
    module: class RMutexModule{},
    providers:[{
      provide: RMutexService,
      useFactory: (options, logger, ttl) => new RMutexService(options, logger, ttl),
      inject: ['RMUTEX_OPTIONS','PinoLogger:RMutexService','RMUTEX_DEFAULT_TTL']
    }],
    exports:[RMutexService]
  }),
  forRootAsync:()=>({
    module: class RMutexModuleAsync{},
    providers:[{
      provide: RMutexService,
      useFactory: (options, logger, ttl) => new RMutexService(options, logger, ttl),
      inject: ['RMUTEX_OPTIONS','PinoLogger:RMutexService','RMUTEX_DEFAULT_TTL']
    }],
    exports:[RMutexService]
  })
};
exports.RMutexService=RMutexService;
exports.RMutexModule=RMutexModule;
JS

# 🧩 ADDITIONAL: Also stub the main @waha/core entry point to ensure our stubs are used
RUN cat > node_modules/@waha/core/index.js <<'JS'
// Main entry stub for @waha/core to ensure our RMutex stub is used
module.exports = require('./dist/common/rmutex');
JS

# Copy full source and ensure build-time installs are up to date
COPY . /git

# 🧩 CRITICAL: Override the real RMutex source in the project itself
# This ensures when yarn build runs, it compiles OUR stub instead of the real code
RUN if [ -d "/git/packages/core/src/common/rmutex" ]; then \
    echo "Overriding real RMutex source with stub..."; \
    mkdir -p /git/packages/core/src/common/rmutex; \
    cat > /git/packages/core/src/common/rmutex/index.ts <<'EOF'
export class RMutexService {
  constructor(options: any, logger: any, ttl: number) {
    console.log('RMutexService PROJECT STUB: Distributed locking disabled');
  }
  async acquireLock(resource: string): Promise<boolean> { return true; }
  async releaseLock(resource: string): Promise<boolean> { return true; }
  async withLock<T>(resource: string, fn: () => Promise<T>): Promise<T> { return await fn(); }
}
export const RMutexModule = {
  forRoot: () => ({ module: class {}, providers: [{ provide: 'RMutexService', useClass: RMutexService }], exports: ['RMutexService'] }),
  forRootAsync: () => ({ module: class {}, providers: [{ provide: 'RMutexService', useClass: RMutexService }], exports: ['RMutexService'] })
};
EOF
fi

RUN yarn install --frozen-lockfile --inline-builds || true

# Build WAHA (core-only)
RUN yarn build && find ./dist -name "*.d.ts" -delete

# Enhanced diagnostic for Redis references
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

# Dashboard stage
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

# GOWS stage
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

# Final runtime image — copy prepared node_modules + dist
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

# Install runtime packages needed for headless Chromium + ffmpeg
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg libvips zip unzip wget ca-certificates tini \
    xvfb xauth libc6 libnss3 libxss1 libasound2 libatk-bridge2.0-0 libgtk-3-0 libdrm2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy prepared artifacts from build stage
COPY --from=build /git/node_modules ./node_modules
COPY --from=build /git/dist ./dist

# Attach dashboard and GOWS
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

# Ensure entrypoint exists if present in repo; make executable
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh || true

# Chokidar options
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

# WAHA variables
ENV WAHA_ZIPPER=ZIPUNZIP

# Expose port and run
EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
