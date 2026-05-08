# syntax=docker/dockerfile:1.7

# ZAQ_VERSION is set by CI to match the release tag (e.g. 0.8.1).
# Defaults to latest for local builds.
ARG ZAQ_IMAGE=ghcr.io/www-zaq-ai/zaq
ARG ZAQ_VERSION=latest

# Pull the pre-built ZAQ release from GHCR (override ZAQ_IMAGE for local builds)
FROM ${ZAQ_IMAGE}:${ZAQ_VERSION} AS zaq

# Base on ParadeDB (postgres 16 + paradedb extension)
FROM paradedb/paradedb:0.23.0

# Install ZAQ runtime deps + supervisord for multi-process management
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      supervisor \
      python3 python3-venv python3-pip \
      libstdc++6 openssl libncurses6 locales ca-certificates \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# Match the appuser from the ZAQ image (uid 1000)
RUN useradd --system --uid 1000 --create-home --home-dir /app appuser

# Copy ZAQ Elixir release
COPY --from=zaq --chown=appuser:appuser /app /app

# Build Python venv for ZAQ's ingestion crawler
RUN python3 -m venv /app/.venv && \
    /app/.venv/bin/pip install --no-cache-dir \
      -r /app/lib/zaq-*/priv/python/crawler-ingest/requirements.txt && \
    chown -R appuser:appuser /app/.venv

# Pre-create ingestion volume directories inside the image
RUN mkdir -p /zaq/volumes/documents && \
    chown -R appuser:appuser /zaq/volumes

# PostgreSQL data directory
RUN mkdir -p /var/lib/postgresql/data && \
    chown -R postgres:postgres /var/lib/postgresql/data

# Process management + startup scripts
COPY supervisord.conf /etc/supervisor/conf.d/zaq-all.conf
COPY start-zaq.sh /start-zaq.sh
COPY docker-entrypoint-single.sh /docker-entrypoint-single.sh
RUN chmod +x /start-zaq.sh /docker-entrypoint-single.sh

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    HOME=/app \
    PGDATA=/var/lib/postgresql/data \
    POSTGRES_DB=zaq_prod \
    POSTGRES_USER=postgres \
    POSTGRES_PASSWORD=postgres \
    DATABASE_URL=ecto://postgres:postgres@127.0.0.1:5432/zaq_prod \
    INGESTION_VOLUMES=documents \
    INGESTION_VOLUMES_BASE=/zaq/volumes
# SECRET_KEY_BASE and SYSTEM_CONFIG_ENCRYPTION_KEY are auto-generated on first
# boot and persisted in /var/lib/postgresql/zaq_secrets.env (inside the volume).

# Declare volumes so Docker persists them across container restarts
VOLUME ["/var/lib/postgresql/data", "/zaq/volumes"]

EXPOSE 4000

ENTRYPOINT ["/docker-entrypoint-single.sh"]
