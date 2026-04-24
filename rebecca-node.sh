#!/usr/bin/env bash
set -euo pipefail

TARGET_URL="${REBECCA_NODE_INSTALLER_URL:-https://raw.githubusercontent.com/rebeccapanel/Rebecca/master/scripts/rebecca/rebecca-node.sh}"

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to load the Rebecca Node installer." >&2
    exit 1
fi

exec bash -s -- "$@" < <(curl -fsSL "$TARGET_URL")
