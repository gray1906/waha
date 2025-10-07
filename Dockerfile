# ======================================================
# === WAHA Core - Redis-Free Lightweight Dockerfile ===
# ======================================================

# ---------------------------
# 1️⃣ Base build stage
# ---------------------------
FROM node:18-alpine AS build

WORKDIR /app

# Copy package files first for caching
COPY package*.json yarn.lock* ./

# Install dependencies safely
RUN yarn install --frozen-lockfile

# Copy the rest of the app
COPY . .

# Build the WAHA application (if applicable)
RUN yarn build || echo "⚠️ No build step detected, continuing..."

# ---------------------------
# 2️⃣ Final runtime image
# ---------------------------
FROM node:18-alpine AS release

WORKDIR /app

# Copy built artifacts and node_modules from build stage
COPY --from=build /app /app

# ==============================
# Environment configuration
# ==============================
ENV PORT=3000 \
    WAHA_CORE_ENABLED=true \
    WAHA_APPS_ENABLED=true \
    WAHA_VERSION=core \
    DB_TYPE=sqlite \
    DB_SQLITE_FILENAME=/app/sessions.db \
    WAHA_REDIS_ENABLED=false \
    WAHA_DISABLE_REDIS=true \
    WAHA_REDIS_HOST=none \
    LOG_LEVEL=info

# Expose WAHA port
EXPOSE 3000

# -------------------------------------------------------
# 3️⃣ Preserve any existing entrypoint as /entrypoint.orig
# -------------------------------------------------------
COPY entrypoint.sh /entrypoint.orig
RUN chmod +x /entrypoint.orig || true

# -------------------------------------------------------
# 4️⃣ Create a Redis-stubbing entrypoint wrapper
# -------------------------------------------------------
RUN cat > /entrypoint.sh <<'SH'
#!/bin/sh
set -e

echo "[waha-entrypoint] Ensuring ioredis stub exists..."

mkdir -p /app/node_modules/ioredis

# Write safe no-network Redis stub
cat > /app/node_modules/ioredis/index.js.tmp <<'JS'
/**
 * ioredis runtime stub — prevents any Redis network connections.
 * Exports a class with expected methods; no network I/O.
 */
module.exports = class Redis {
  constructor(){ this.isStub = true; }
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

mv /app/node_modules/ioredis/index.js.tmp /app/node_modules/ioredis/index.js
chmod 644 /app/node_modules/ioredis/index.js || true

echo "[waha-entrypoint] ioredis stub written to /app/node_modules/ioredis/index.js"

# Run the original entrypoint if it exists
if [ -x /entrypoint.orig ]; then
  echo "[waha-entrypoint] Executing original entrypoint /entrypoint.orig"
  exec /entrypoint.orig "$@"
fi

# Fallback: direct Node start
if [ -f /app/dist/main.js ]; then
  echo "[waha-entrypoint] Starting WAHA via node /app/dist/main.js"
  exec node /app/dist/main.js
fi

# Final fallback: execute passed command
exec "$@"
SH

RUN chmod +x /entrypoint.sh

# ---------------------------
# 5️⃣ Final command
# ---------------------------
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
