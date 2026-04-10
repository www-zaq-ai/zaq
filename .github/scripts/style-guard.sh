#!/usr/bin/env bash

set -euo pipefail

BASE_REF="${GITHUB_BASE_REF:-main}"

git fetch --no-tags --depth=1 origin "$BASE_REF"

VIOLATIONS="$({
  git diff --unified=0 --no-color "origin/${BASE_REF}...HEAD" -- \
    'assets/**/*.{css,scss,sass,pcss,js,ts,tsx}' \
    'lib/zaq_web/**/*.{heex,eex,leex,ex}' \
    ':(exclude)assets/vendor/**' \
    ':(exclude)**/*.min.*' \
  | rg -n '^\+[^+].*(#[0-9A-Fa-f]{3,8}\b|font-family\s*:)' \
  | rg -v 'style-guard:allow' || true
} )"

if [ -n "$VIOLATIONS" ]; then
  printf '%s\n' "UI style guard failed (new hardcoded hex color or font-family):"
  printf '%s\n' "$VIOLATIONS"
  exit 1
fi

printf '%s\n' "UI style guard passed."
