#!/bin/bash
set -euo pipefail

# Wrapper to call the relocated ACL engine when invoked from repo root
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/engine.sh" "$@"

