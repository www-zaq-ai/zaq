#!/bin/bash
set -e

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-zaq_prod}"

# ── Secrets bootstrap ────────────────────────────────────────────────────────
# Generate SECRET_KEY_BASE and SYSTEM_CONFIG_ENCRYPTION_KEY once, persist them
# in the postgres data volume so they survive container restarts.
SECRETS_FILE="/var/lib/postgresql/zaq_secrets.env"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "[init] Generating persistent secrets..."
  mkdir -p "$(dirname "$SECRETS_FILE")"
  {
    echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')"
    echo "SYSTEM_CONFIG_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '\n')"
  } > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
fi

# Export so supervisord and all child processes inherit them (unless already set)
# shellcheck source=/dev/null
set -a
source "$SECRETS_FILE"
set +a

# Allow caller-supplied values to override the persisted ones
[ -n "${SECRET_KEY_BASE_OVERRIDE:-}" ]              && export SECRET_KEY_BASE="$SECRET_KEY_BASE_OVERRIDE"
[ -n "${SYSTEM_CONFIG_ENCRYPTION_KEY_OVERRIDE:-}" ] && export SYSTEM_CONFIG_ENCRYPTION_KEY="$SYSTEM_CONFIG_ENCRYPTION_KEY_OVERRIDE"

# Warn on first boot if data directory looks like an anonymous/ephemeral volume
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "⚠️  WARNING: No named volume detected for /var/lib/postgresql/data."
  echo "   Data will be lost if this container is removed."
  echo "   Run with: -v zaq-pgdata:/var/lib/postgresql/data -v zaq-volumes:/zaq/volumes"
fi

# Initialize PostgreSQL on first boot
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "[init] Initializing PostgreSQL data directory..."

  PWFILE="/var/lib/postgresql/.pwfile"
  echo "$POSTGRES_PASSWORD" > "$PWFILE"
  chown postgres:postgres "$PWFILE"
  chmod 600 "$PWFILE"

  gosu postgres initdb \
    --username="$POSTGRES_USER" \
    --pwfile="$PWFILE" \
    --encoding=UTF8 \
    --locale=en_US.UTF-8 \
    -D "$PGDATA"

  rm -f "$PWFILE"

  # Allow TCP connections from localhost (used by ZAQ via DATABASE_URL)
  {
    echo "host all all 127.0.0.1/32 scram-sha-256"
    echo "host all all ::1/128      scram-sha-256"
  } >> "$PGDATA/pg_hba.conf"

  # Briefly start postgres to create the application database
  gosu postgres pg_ctl -D "$PGDATA" -o "-c listen_addresses='127.0.0.1'" -w start

  gosu postgres psql -U "$POSTGRES_USER" -c "CREATE DATABASE \"$POSTGRES_DB\";" postgres

  gosu postgres pg_ctl -D "$PGDATA" -m fast -w stop

  echo "[init] PostgreSQL initialization complete."
fi

# Hand off to supervisord which manages postgres + zaq
exec supervisord -n -c /etc/supervisor/supervisord.conf
