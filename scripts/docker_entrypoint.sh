#!/bin/sh
# Default release startup is unchanged. Provisioning never loads the application.
set -eu

# Compose supplies the bundled database identity. Keep an explicit URL untouched for
# non-Compose deployments; quote credentials so punctuation cannot corrupt the URI.
owner_database_url() {
  if [ -z "${DATABASE_URL:-}" ] && [ -n "${PGHOST:-}" ]; then
    : "${ZAQ_OWNER_PASSWORD:?Required owner password for bundled database}"
    export DATABASE_URL
    DATABASE_URL=$(python3 -c '
import os
from urllib.parse import quote

user = quote(os.environ.get("ZAQ_OWNER", "zaq_owner"), safe="")
password = quote(os.environ["ZAQ_OWNER_PASSWORD"], safe="")
database = quote(os.environ.get("ZAQ_DATABASE", "zaq_prod"), safe="")
host = os.environ["PGHOST"]
port = os.environ.get("PGPORT", "5432")
print(f"postgresql://{user}:{password}@{host}:{port}/{database}")
')
  fi
}

case "${1:-server}" in
  provision-db)
    shift
    case " $* " in *' --automatic '*) owner_database_url ;; esac
    exec sh "$(dirname "$0")/provision_database.sh" "$@"
    ;;
  adopt-existing-db)
    shift
    owner_database_url
    exec sh "$(dirname "$0")/provision_database.sh" --adopt-existing "$@"
    ;;
  transfer-legacy-db)
    shift
    exec sh "$(dirname "$0")/transfer_legacy_database.sh" "$@"
    ;;
  server)
    if [ "$#" -gt 1 ]; then
      printf '%s\n' 'Server mode takes no arguments.' >&2
      exit 1
    fi
    owner_database_url
    /app/bin/zaq eval 'Zaq.Release.migrate()'
    exec /app/bin/zaq start
    ;;
  *) exec "$@" ;;
esac
