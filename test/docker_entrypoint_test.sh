#!/bin/sh
# Regression check for Compose's automatic owner URL (no Docker daemon required).
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# Intercept only the final `exec sh provision_database.sh ...`, not the entrypoint.
cat > "$tmp/sh" <<'EOF'
#!/bin/sh
printf '%s\n' "${DATABASE_URL:-}"
EOF
chmod +x "$tmp/sh"

actual=$(env -u DATABASE_URL PATH="$tmp:$PATH" PGHOST=postgres \
  ZAQ_OWNER=zaq_owner ZAQ_DATABASE=zaq_prod \
  ZAQ_OWNER_PASSWORD='owner:p@ss/word' \
  /bin/sh "$root/scripts/docker_entrypoint.sh" provision-db --automatic)
expected='postgresql://zaq_owner:owner%3Ap%40ss%2Fword@postgres:5432/zaq_prod'
[ "$actual" = "$expected" ] || { printf '%s\n' 'Derived owner URL mismatch' >&2; exit 1; }

actual=$(env PATH="$tmp:$PATH" PGHOST=postgres \
  ZAQ_OWNER_PASSWORD='ignored' DATABASE_URL='postgresql://explicit@example/zaq' \
  /bin/sh "$root/scripts/docker_entrypoint.sh" provision-db --automatic)
[ "$actual" = 'postgresql://explicit@example/zaq' ] || {
  printf '%s\n' 'Explicit owner URL was changed' >&2; exit 1;
}

if env -u DATABASE_URL -u ZAQ_OWNER_PASSWORD PATH="$tmp:$PATH" PGHOST=postgres \
  /bin/sh "$root/scripts/docker_entrypoint.sh" provision-db --automatic >/dev/null 2>&1; then
  printf '%s\n' 'Missing owner password was accepted' >&2
  exit 1
fi

printf '%s\n' 'Docker entrypoint URL checks passed'
