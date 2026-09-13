#!/bin/sh
# Thin psql dispatcher. All credentials stay in the environment, never argv/files.
set -eu

fail() { printf '%s\n' "$1" >&2; exit 1; }
automatic=false
engine=auto
while [ "$#" -gt 0 ]; do
  case "$1" in
    --automatic) automatic=true; shift ;;
    --engine|--database|--owner|--reader)
      [ "$#" -ge 2 ] || fail "Missing value for $1"
      case "$1" in
        --engine) engine=$2 ;;
        --database) ZAQ_DATABASE=$2 ;;
        --owner) ZAQ_OWNER=$2 ;;
        --reader) ZAQ_READER=$2 ;;
      esac
      shift 2
      ;;
    *) fail 'Unknown provisioning option.' ;;
  esac
done
case "$engine" in auto|postgres|paradedb) ;; *) fail 'Expected engine auto, postgres or paradedb.' ;; esac
: "${ZAQ_DATABASE:?Required target database}" "${ZAQ_OWNER:?Required owner login}"
: "${ZAQ_READER:?Required reader login}" "${ZAQ_OWNER_PASSWORD:?Required owner password}"
: "${ZAQ_READER_PASSWORD:?Required reader password}"
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}" PGDATABASE="${PGDATABASE:-postgres}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
if [ "$automatic" = true ]; then
  : "${DATABASE_URL:?Required application-owner DATABASE_URL}"
  case "$DATABASE_URL" in
    ecto://*) ZAQ_OWNER_DATABASE_URL="postgresql://${DATABASE_URL#ecto://}" ;;
    postgres://*|postgresql://*) ZAQ_OWNER_DATABASE_URL=$DATABASE_URL ;;
    *) fail 'DATABASE_URL must be an owner PostgreSQL URL.' ;;
  esac
  export ZAQ_OWNER_DATABASE_URL
fi

scripts=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ "$engine" = auto ]; then
  engine=$(psql -X -w -qAt --set ON_ERROR_STOP=1 <<'SQL'
SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_search')
THEN 'paradedb' ELSE 'postgres' END;
SQL
  )
fi
case "$engine" in postgres|paradedb) ;; *) fail 'Unexpected engine probe result.' ;; esac
script="$scripts/setup_${engine}_extensions.sql"
if [ "$automatic" = true ]; then script="$scripts/docker_database_setup.sql"; fi
psql -X -w -q --set ON_ERROR_STOP=1 \
  --set "zaq_database=$ZAQ_DATABASE" --set "zaq_owner=$ZAQ_OWNER" \
  --set "zaq_reader=$ZAQ_READER" --set "zaq_bootstrap_engine=$engine" --file "$script"

if [ "$automatic" = true ]; then
  # Suppress libpq URI diagnostics, which can include credentials on malformed URLs.
  if ! psql -X -w -q --set ON_ERROR_STOP=1 \
    --set "zaq_database=$ZAQ_DATABASE" --set "zaq_owner=$ZAQ_OWNER" \
    --file "$scripts/docker_database_authenticate.sql" >/dev/null 2>&1; then
    fail 'DATABASE_URL must authenticate as the provisioned owner against the same database/server.'
  fi
  for role in owner reader; do
    case "$role" in
      owner) login=$ZAQ_OWNER; password=$ZAQ_OWNER_PASSWORD ;;
      reader) login=$ZAQ_READER; password=$ZAQ_READER_PASSWORD ;;
    esac
    if ! PGUSER="$login" PGPASSWORD="$password" PGDATABASE="$ZAQ_DATABASE" \
      psql -X -w -q --set ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
      fail 'Supplied owner/reader credentials failed validation; use explicit DBA maintenance, not bootstrap, for rotation.'
    fi
  done
  printf '%s\n' 'Database bootstrap verified; supplied owner credentials are ready.'
fi
