#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"

echo "Safer upgrade starting..."

if [[ -d "$ROOT_DIR/.git" ]]; then
  echo "Fetching updates..."
  git -C "$ROOT_DIR" fetch --all --prune
  echo "Creating backup tag..."
  ts="$(date +%Y%m%d%H%M%S)"
  git -C "$ROOT_DIR" tag -f "pre-upgrade-$ts" || true
  echo "Rebasing local changes onto origin/main..."
  git -C "$ROOT_DIR" pull --rebase --autostash origin main || {
    echo "Rebase failed. You can rollback with: git reset --hard pre-upgrade-$ts" >&2
    exit 1
  }
else
  echo "Not a git repository; skipping fetch/pull." >&2
fi

echo "Re-running bootstrap after upgrade..."
"$ROOT_DIR/bin/bootstrap" || true

echo "Upgrade complete."

