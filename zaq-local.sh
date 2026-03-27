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
PGVECTOR_SERVICE="pgvector"
ZAQ_URL="http://localhost:4000"

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
    printf '%s\n' "${running}" | grep -qx "${PGVECTOR_SERVICE}"
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
  docker compose logs --tail=100 -f
}

main() {
  check_os
  check_docker

  if ! directory_is_empty; then
    if artifacts_exist; then
      info "Detected existing ZAQ local artifacts (${COMPOSE_FILE}, ${ENV_FILE}, ${INGESTION_DIR})."
      if services_running; then
        info "Containers already running. Jumping directly to log UI."
        show_ui
        exit 0
      fi

      info "Artifacts found but services not running. Jumping to container start."
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
