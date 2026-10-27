#!/bin/sh
# Real-provider Channels tests. Every invocation owns its Compose project.
set -eu

ZAQ_FILE_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZAQ_FILE_COMPOSE="$ZAQ_FILE_REPO/test/support/file_delivery/docker-compose.yml"
ZAQ_FILE_PROJECT="zaq-files-$(date +%s)-$$"
ZAQ_FILE_RUNTIME=$(mktemp -d)

cleanup() {
  docker compose -p "$ZAQ_FILE_PROJECT" -f "$ZAQ_FILE_COMPOSE" down --volumes --remove-orphans >/dev/null || true
  rm -rf "$ZAQ_FILE_RUNTIME"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

docker compose -p "$ZAQ_FILE_PROJECT" -f "$ZAQ_FILE_COMPOSE" up --detach
python3 "$ZAQ_FILE_REPO/test/support/file_delivery/bootstrap.py" \
  "$ZAQ_FILE_PROJECT" "$ZAQ_FILE_COMPOSE" "$ZAQ_FILE_RUNTIME/services.json"

cd "$ZAQ_FILE_REPO"
ZAQ_FILE_DELIVERY_SERVICES="$ZAQ_FILE_RUNTIME/services.json" mix test \
  test/zaq/channels/disk_file_delivery_integration_test.exs \
  test/zaq/channels/email_file_delivery_integration_test.exs \
  --include integration --max-cases 2
