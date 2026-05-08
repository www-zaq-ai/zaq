#!/bin/sh
set -e

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-zaq_prod}"

echo "[zaq] Waiting for PostgreSQL to be ready..."
until pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q; do
  sleep 1
done

echo "[zaq] Running database migrations..."
/app/bin/zaq eval "Zaq.Release.migrate()"

echo "[zaq] Starting ZAQ..."
exec /app/bin/zaq start
