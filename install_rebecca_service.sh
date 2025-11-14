#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer must be run as root."
    exit 1
fi

SCRIPT_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh"
TMP_SCRIPT=$(mktemp)
trap 'rm -f "$TMP_SCRIPT"' EXIT

if ! curl -fsSL "$SCRIPT_URL" -o "$TMP_SCRIPT"; then
    echo "Failed to download rebecca.sh from $SCRIPT_URL"
    exit 1
fi

chmod +x "$TMP_SCRIPT"

exec bash "$TMP_SCRIPT" install service "$@"
