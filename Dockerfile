# ================================
#       BUILD STAGE
# ================================
FROM node:18-bullseye AS build

# Set working directory
WORKDIR /app

# Enable Corepack for Yarn 3.x
RUN corepack enable

# Copy dependency files first (better caching)
COPY package.json yarn.lock ./

# Install dependencies using Yarn 3
RUN yarn install --frozen-lockfile

# Copy the rest of the application code
COPY . .

# ================================
#       RUNTIME STAGE
# ================================
FROM node:18-slim AS runtime

WORKDIR /app

# Copy built app and node_modules from build stage
COPY --from=build /app /app

# Add tini (for process management in containers)
RUN apt-get update && apt-get install -y tini && rm -rf /var/lib/apt/lists/*

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Environment configuration (example)
ENV NODE_ENV=production \
    PORT=3000 \
    WAHA_CORE_ENABLED=true \
    WAHA_VERSION=NOWEB \
    LOG_LEVEL=info \
    WAHA_DASHBOARD_USERNAME=admin \
    WAHA_DASHBOARD_PASSWORD=AdminPass2024! \
    WAHA_API_KEY_PLAIN=MyWahaPro2024! \
    WAHA_REDIS_ENABLED=false

# Expose app port
EXPOSE 3000

# Use tini as entrypoint to handle PID 1
ENTRYPOINT ["/usr/bin/tini", "--"]

# Start the app
CMD ["/entrypoint.sh"]ENV WAHA_GOWS_PATH=/app/gows
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
