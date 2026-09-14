#!/bin/sh
# Default release startup is unchanged. Provisioning never loads the application.
set -eu

case "${1:-server}" in
  provision-db)
    shift
    exec sh "$(dirname "$0")/provision_database.sh" "$@"
    ;;
  server)
    if [ "$#" -gt 1 ]; then
      printf '%s\n' 'Server mode takes no arguments.' >&2
      exit 1
    fi
    /app/bin/zaq eval 'Zaq.Release.migrate()'
    exec /app/bin/zaq start
    ;;
  *) exec "$@" ;;
esac
