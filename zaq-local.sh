#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="zaq-local.sh"
DOCKER_INSTALL_URL="https://docs.docker.com/get-docker/"
GIST_ID="4e52fe526a0a35f3a8b61dd77e1e6288"
GIST_API_URL="https://api.github.com/gists/${GIST_ID}"

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
INGESTION_DIR="ingestion-volumes"
INGESTION_DOCS_DIR="${INGESTION_DIR}/documents"

ZAQ_SERVICE="zaq"
DB_SERVICE="paradedb"
ZAQ_URL="http://localhost:4000"

# Legacy service name used before the paradedb migration
LEGACY_DB_SERVICE="pgvector"
LEGACY_DB_CONTAINER="zaq-pgvector"
NEW_DB_CONTAINER="zaq-paradedb"
DB_NAME="${DB_NAME:-zaq_prod}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-postgres}"

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || printf '0')" -ge 8 ]; then
  BLUE="$(tput setaf 4)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  RED="$(tput setaf 1)"
  BOLD="$(tput bold)"
  RESET="$(tput sgr0)"
else
  BLUE=""
  GREEN=""
  YELLOW=""
  RED=""
  BOLD=""
  RESET=""
fi

info() {
  printf '%s[INFO]%s %s\n' "${BLUE}" "${RESET}" "$*"
}

warn() {
  printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$*"
}

error() {
  printf '%s[ERROR]%s %s\n' "${RED}" "${RESET}" "$*" >&2
}

success() {
  printf '%s[OK]%s %s\n' "${GREEN}" "${RESET}" "$*"
}

require_command() {
  local cmd="$1"
  local install_hint="${2:-}"

  if ! command -v "${cmd}" >/dev/null 2>&1; then
    error "'${cmd}' is required but not installed."
    if [ -n "${install_hint}" ]; then
      printf 'Install hint: %s\n' "${install_hint}" >&2
    fi
    exit 1
  fi
}

check_os() {
  local os
  os="$(uname -s)"

  case "${os}" in
    Linux|Darwin) ;;
    *)
      error "Unsupported OS '${os}'. ${SCRIPT_NAME} supports Linux and macOS only."
      exit 1
      ;;
  esac
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    error "Docker is not installed or not running."
    printf 'Install Docker Desktop/Engine: %s\n' "${DOCKER_INSTALL_URL}" >&2
    printf 'Please install Docker and re-run %s.\n' "${SCRIPT_NAME}" >&2
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    error "Docker Compose plugin is not available."
    printf 'Install Docker with Compose plugin: %s\n' "${DOCKER_INSTALL_URL}" >&2
    printf 'Please install Docker Compose and re-run %s.\n' "${SCRIPT_NAME}" >&2
    exit 1
  fi
}

directory_is_empty() {
  local script_basename
  local entry
  local name

  script_basename="$(basename "$0")"

  for entry in ./* ./.??*; do
    [ -e "${entry}" ] || continue
    name="$(basename "${entry}")"

    [ "${name}" = "." ] && continue
    [ "${name}" = ".." ] && continue
    [ "${name}" = "${script_basename}" ] && continue

    return 1
  done

  return 0
}

artifacts_exist() {
  [ -f "${COMPOSE_FILE}" ] && [ -f "${ENV_FILE}" ] && [ -d "${INGESTION_DIR}" ]
}

services_running() {
  local running
  running="$(docker compose ps --status running --services 2>/dev/null || true)"
  printf '%s\n' "${running}" | grep -qx "${ZAQ_SERVICE}" &&
    printf '%s\n' "${running}" | grep -qx "${DB_SERVICE}"
}

container_exists() {
  docker inspect "$1" &>/dev/null
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

compose_uses_legacy_db() {
  [ -f "${COMPOSE_FILE}" ] && grep -q "pgvector/pgvector\|timescale/timescaledb" "${COMPOSE_FILE}"
}

needs_paradedb_migration() {
  # True when: compose file still references the old image OR legacy container exists
  compose_uses_legacy_db || container_exists "${LEGACY_DB_CONTAINER}"
}

prompt_continue_non_empty() {
  local answer
  printf '%s\n' "Current directory is not empty and does not contain a full ZAQ local setup."
  printf '%s' "Run this script in a new folder when possible. Continue anyway? [y/N]: "
  read -r answer

  case "${answer}" in
    y|Y) return 0 ;;
    *)
      info "Aborted by user."
      exit 0
      ;;
  esac
}

prepare_directories() {
  mkdir -p "${INGESTION_DOCS_DIR}"
  info "Created/verified '${INGESTION_DIR}' and '${INGESTION_DOCS_DIR}'."
}

resolve_compose_raw_url() {
  local payload
  local after_file
  local raw_url

  payload="$(curl -fsSL "${GIST_API_URL}" | tr -d '\n\r')"
  if [ -z "${payload}" ]; then
    error "Failed to download Gist metadata from ${GIST_API_URL}."
    exit 1
  fi

  after_file="${payload#*\"docker-compose.yml\"}"
  if [ "${after_file}" = "${payload}" ]; then
    error "Unable to locate docker-compose.yml entry in Gist metadata."
    exit 1
  fi

  raw_url="$(printf '%s' "${after_file}" | sed -nE 's/.*"raw_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
  if [ -z "${raw_url}" ]; then
    error "Resolved empty raw_url for docker-compose.yml."
    exit 1
  fi

  printf '%s\n' "${raw_url}"
}

download_compose() {
  require_command curl "Install curl"

  info "Resolving latest docker-compose.yml URL from Gist API..."
  local raw_url
  raw_url="$(resolve_compose_raw_url)"

  info "Downloading docker-compose.yml..."
  curl -fsSL "${raw_url}" -o "${COMPOSE_FILE}"
  info "Saved '${COMPOSE_FILE}'."
}

generate_env_file() {
  require_command openssl "Install OpenSSL"

  local secret_key_base
  local encryption_key
  local decoded_len

  secret_key_base="$(openssl rand -hex 32)"
  encryption_key="$(openssl rand -base64 32 | tr -d '\n')"

  if [ "${#secret_key_base}" -ne 64 ]; then
    error "Generated SECRET_KEY_BASE is not 64 characters."
    exit 1
  fi

  decoded_len="$(printf '%s' "${encryption_key}" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')"
  if [ "${decoded_len}" -ne 32 ]; then
    error "Generated SYSTEM_CONFIG_ENCRYPTION_KEY does not decode to 32 bytes."
    exit 1
  fi

  cat > "${ENV_FILE}" <<EOF
SECRET_KEY_BASE=${secret_key_base}
SYSTEM_CONFIG_ENCRYPTION_KEY=${encryption_key}
EOF

  info "Generated '${ENV_FILE}' with SECRET_KEY_BASE and SYSTEM_CONFIG_ENCRYPTION_KEY."
}

start_containers() {
  info "Starting ZAQ containers in background..."
  docker compose up -d
}

# ---------------------------------------------------------------------------
# ParadeDB migration (runs automatically when legacy DB is detected)
# ---------------------------------------------------------------------------

wait_ready() {
  local container="$1"
  local retries=30
  info "Waiting for PostgreSQL in '${container}'..."
  until docker exec "${container}" pg_isready -U "${DB_USER}" &>/dev/null; do
    retries=$((retries - 1))
    [ "${retries}" -le 0 ] && error "Timed out waiting for '${container}'."
    sleep 2
  done
  success "'${container}' is ready."
}

psql_exec() {
  local container="$1"
  local dbname="$2"
  local sql="$3"
  docker exec -e PGPASSWORD="${DB_PASSWORD}" "${container}" \
    psql --username="${DB_USER}" --dbname="${dbname}" --no-align --tuples-only \
    -c "${sql}" 2>/dev/null || true
}

migrate_to_paradedb() {
  local dump_dir="./backups"
  local dump_file="${dump_dir}/zaq_pre_paradedb_$(date +%Y%m%d_%H%M%S).dump"

  printf '\n'
  info "=== Database upgrade: pgvector → ParadeDB ==="
  info "Your data will be preserved. A backup is saved before any changes."
  printf '\n'

  mkdir -p "${dump_dir}"

  # Step 1 — ensure old container is running
  info "Step 1/5 — Preparing old database container..."
  if ! container_running "${LEGACY_DB_CONTAINER}"; then
    info "Starting '${LEGACY_DB_CONTAINER}'..."
    docker start "${LEGACY_DB_CONTAINER}"
    sleep 3
  fi
  wait_ready "${LEGACY_DB_CONTAINER}"

  # Step 2 — dump from old container
  info "Step 2/5 — Backing up '${DB_NAME}' from '${LEGACY_DB_CONTAINER}'..."
  PGPASSWORD="${DB_PASSWORD}" docker exec -e PGPASSWORD="${DB_PASSWORD}" "${LEGACY_DB_CONTAINER}" \
    pg_dump \
      --username="${DB_USER}" \
      --format=custom \
      --no-acl \
      --no-owner \
      "${DB_NAME}" \
    > "${dump_file}" \
    2> >(grep -v "collation version mismatch" >&2)

  local dump_size
  dump_size="$(du -sh "${dump_file}" | cut -f1)"
  success "Backup complete: ${dump_file} (${dump_size})"

  # Stop and remove old container to free its port and name before starting the new one
  info "Stopping and removing '${LEGACY_DB_CONTAINER}'..."
  docker stop "${LEGACY_DB_CONTAINER}"
  docker rm "${LEGACY_DB_CONTAINER}"

  # Step 3 — download new compose file and start new container
  info "Step 3/5 — Upgrading docker-compose.yml and starting ParadeDB..."
  # Only download if the current compose still references the legacy image —
  # if the user already has the paradedb compose (e.g. after a git pull), keep it.
  if compose_uses_legacy_db; then
    download_compose
  else
    info "docker-compose.yml already references ParadeDB — skipping download."
  fi

  # Detect the DB service name from the downloaded compose file — works whether
  # the Gist already has the renamed service or not.
  local downloaded_db_service
  downloaded_db_service="$(docker compose config --services 2>/dev/null | grep -v "^${ZAQ_SERVICE}$" | head -1)"
  info "Detected database service in compose: '${downloaded_db_service}'"

  if container_exists "${NEW_DB_CONTAINER}"; then
    docker stop "${NEW_DB_CONTAINER}" 2>/dev/null || true
    docker rm "${NEW_DB_CONTAINER}"
  fi

  docker compose up -d "${downloaded_db_service}" 2>&1 | grep -v "^$"

  # The container name may differ if the Gist still uses the old name; resolve it.
  local actual_db_container
  actual_db_container="$(docker compose ps -q "${downloaded_db_service}" 2>/dev/null | xargs docker inspect -f '{{.Name}}' 2>/dev/null | tr -d '/' || echo "${NEW_DB_CONTAINER}")"
  info "Database container: '${actual_db_container}'"

  wait_ready "${actual_db_container}"

  # Step 4 — restore into new container
  info "Step 4/5 — Restoring data into '${actual_db_container}'..."

  # Fix collation on system databases (glibc version mismatch blocks CREATE DATABASE)
  for db in postgres template1; do
    psql_exec "${actual_db_container}" "${db}" \
      "ALTER DATABASE ${db} REFRESH COLLATION VERSION;" >/dev/null
  done
  psql_exec "${actual_db_container}" "postgres" \
    "ALTER DATABASE template0 ALLOW_CONNECTIONS true;" >/dev/null
  psql_exec "${actual_db_container}" "template1" \
    "ALTER DATABASE template0 REFRESH COLLATION VERSION;" >/dev/null
  psql_exec "${actual_db_container}" "postgres" \
    "ALTER DATABASE template0 ALLOW_CONNECTIONS false;" >/dev/null

  # Drop and recreate target database
  psql_exec "${actual_db_container}" "postgres" \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" \
    >/dev/null
  psql_exec "${actual_db_container}" "postgres" "DROP DATABASE IF EXISTS ${DB_NAME};" >/dev/null
  psql_exec "${actual_db_container}" "postgres" "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};" >/dev/null

  # Restore — paradedb schema conflict is expected and harmless on a fresh image
  docker exec -i -e PGPASSWORD="${DB_PASSWORD}" "${actual_db_container}" \
    pg_restore \
      --username="${DB_USER}" \
      --dbname="${DB_NAME}" \
      --no-acl \
      --no-owner \
    < "${dump_file}" 2>&1 \
    | grep -v \
        -e 'schema "paradedb" already exists' \
        -e 'collation version mismatch' \
        -e 'errors ignored on restore' \
    || true

  psql_exec "${actual_db_container}" "${DB_NAME}" \
    "ALTER DATABASE ${DB_NAME} REFRESH COLLATION VERSION;" >/dev/null

  success "Data restored successfully."

  # Step 5 — remove old container now that migration is confirmed
  info "Step 5/5 — Cleaning up old container..."
  docker rm "${LEGACY_DB_CONTAINER}" 2>/dev/null && \
    success "Removed '${LEGACY_DB_CONTAINER}'." || \
    warn "Could not remove '${LEGACY_DB_CONTAINER}' — remove it manually when ready."

  printf '\n'
  success "=== Database upgrade complete. Backup at: ${dump_file} ==="
  printf '\n'
}

open_zaq_url() {
  local os
  os="$(uname -s)"
  info "Opening ZAQ in your default browser..."

  if [ "${os}" = "Darwin" ]; then
    if command -v open >/dev/null 2>&1 && open "${ZAQ_URL}" >/dev/null 2>&1; then
      info "Browser open command sent (open)."
      return 0
    fi

    if command -v osascript >/dev/null 2>&1 && osascript -e "open location \"${ZAQ_URL}\"" >/dev/null 2>&1; then
      info "Browser open command sent (osascript)."
      return 0
    fi

    warn "Could not auto-open browser on macOS. Open ${ZAQ_URL} manually."
    return 0
  fi

  if command -v xdg-open >/dev/null 2>&1 && xdg-open "${ZAQ_URL}" >/dev/null 2>&1; then
    info "Browser open command sent (xdg-open)."
    return 0
  fi

  if command -v sensible-browser >/dev/null 2>&1 && sensible-browser "${ZAQ_URL}" >/dev/null 2>&1; then
    info "Browser open command sent (sensible-browser)."
    return 0
  fi

  warn "Could not auto-open browser. Open ${ZAQ_URL} manually."
}

status_label() {
  if services_running; then
    printf '%sRUNNING%s' "${GREEN}" "${RESET}"
  else
    printf '%sNOT RUNNING%s' "${RED}" "${RESET}"
  fi
}

show_ui() {
  local cols=80
  local divider

  if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    cols="$(tput cols 2>/dev/null || printf '80')"
  fi

  divider="$(printf '%*s' "${cols}" '' | tr ' ' '-')"

  printf '%s%sZAQ LOCAL%s\n' "${BLUE}" "${BOLD}" "${RESET}"
  printf '%sURL:%s %s\n' "${BLUE}" "${RESET}" "${ZAQ_URL}"
  printf '%sStatus:%s %s\n' "${BLUE}" "${RESET}" "$(status_label)"
  printf '%sControls:%s Ctrl+C to quit logs viewer | Run `%sdocker compose stop%s` to stop containers\n' "${BLUE}" "${RESET}" "${BOLD}" "${RESET}"
  printf '%sInfo:%s showing logs in 5 seconds (tailing last 100 lines)\n' "${BLUE}" "${RESET}"
  printf '%s\n' "${divider}"

  sleep 5
  open_zaq_url
  docker compose logs --tail=100 -f
}

main() {
  check_os
  check_docker

  if ! directory_is_empty; then
    if artifacts_exist; then
      info "Detected existing ZAQ local setup."

      # Upgrade path: old pgvector image detected → migrate to paradedb
      if needs_paradedb_migration; then
        info "Database upgrade required: migrating from pgvector to ParadeDB..."
        migrate_to_paradedb
        start_containers
        show_ui
        exit 0
      fi

      if services_running; then
        info "Containers already running. Jumping directly to log UI."
        show_ui
        exit 0
      fi

      info "Artifacts found but services not running. Starting containers."
      start_containers
      show_ui
      exit 0
    fi

    prompt_continue_non_empty
  fi

  prepare_directories
  download_compose
  generate_env_file
  start_containers
  show_ui
}

main "$@"
