#!/bin/sh
# DBA-only, preview-first repair for a legacy postgres-owned ZAQ database.
set -eu

case "${1:-}" in
  '') apply=false ;;
  --apply) apply=true; shift ;;
  *) printf '%s\n' 'Usage: transfer-legacy-db [--apply]' >&2; exit 1 ;;
esac
[ "$#" -eq 0 ] || { printf '%s\n' 'Usage: transfer-legacy-db [--apply]' >&2; exit 1; }
: "${ZAQ_DATABASE:?Set the existing ZAQ_DATABASE}"
: "${ZAQ_OWNER:?Set the requested ZAQ_OWNER}"
: "${ZAQ_READER:?Set the requested ZAQ_READER}"
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}" PGDATABASE="${PGDATABASE:-postgres}"

exec psql -X -w -v ON_ERROR_STOP=1 \
  --set "zaq_database=$ZAQ_DATABASE" --set "zaq_owner=$ZAQ_OWNER" \
  --set "zaq_reader=$ZAQ_READER" --set "zaq_apply=$apply" \
  --file "$(dirname "$0")/transfer_legacy_database.sql"
