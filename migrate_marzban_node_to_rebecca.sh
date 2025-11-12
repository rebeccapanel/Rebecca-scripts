#!/usr/bin/env bash
set -euo pipefail

OLD_APP_DIR="/opt/marzban-node"
NEW_APP_DIR="/opt/rebecca-node"
OLD_DATA_DIR="/var/lib/marzban-node"
NEW_DATA_DIR="/var/lib/rebecca-node"
OLD_SERVICE_NAME="marzban-node"
NEW_SERVICE_NAME="rebecca-node"
NODE_SCRIPT_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca-node.sh"

log() {
    echo -e "\e[96m[rebecca-node-migrate]\e[0m $1"
}

warn() {
    echo -e "\e[93m[rebecca-node-migrate]\e[0m $1"
}

error_exit() {
    echo -e "\e[91m[rebecca-node-migrate]\e[0m $1"
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be executed as root."
    fi
}

compose_binary() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
        return
    fi
    if command -v docker >/dev/null 2>&1; then
        echo "docker compose"
        return
    fi
    error_exit "Docker compose was not found. Please install Docker before migrating."
}

safe_move_directory() {
    local source="$1"
    local destination="$2"
    if [ -d "$source" ]; then
        if [ -d "$destination" ]; then
            warn "$destination already exists. Skipping move from $source."
        else
            mv "$source" "$destination"
            log "Moved $source to $destination"
        fi
    else
        warn "$source not found. Skipping."
    fi
}

rewrite_paths() {
    local file="$1"
    if [ -f "$file" ]; then
        sed -i \
            -e 's#/var/lib/marzban-node#/var/lib/rebecca-node#g' \
            -e 's#/opt/marzban-node#/opt/rebecca-node#g' \
            -e 's/Marzban-node/Rebecca-node/g' \
            -e 's/marzban-node/rebecca-node/g' \
            "$file"
        sed -i '/SERVICE_PROTOCOL/d' "$file"
        log "Updated references inside $file"
    else
        warn "$file not found. Skipping."
    fi
}

migrate_systemd_service() {
    local service_path="/etc/systemd/system/${OLD_SERVICE_NAME}.service"
    if [ -f "$service_path" ]; then
        systemctl stop "${OLD_SERVICE_NAME}" >/dev/null 2>&1 || true
        sed -i \
            -e 's#/var/lib/marzban-node#/var/lib/rebecca-node#g' \
            -e 's#/opt/marzban-node#/opt/rebecca-node#g' \
            -e 's/Marzban-node/Rebecca-node/g' \
            -e 's/marzban-node/rebecca-node/g' \
            "$service_path"
        mv "$service_path" "/etc/systemd/system/${NEW_SERVICE_NAME}.service"
        systemctl daemon-reload
        systemctl enable --now "${NEW_SERVICE_NAME}.service"
        log "Updated systemd service to ${NEW_SERVICE_NAME}.service"
    else
        warn "No systemd service found for ${OLD_SERVICE_NAME}. Skipping."
    fi
}

install_node_cli() {
    if ! command -v curl >/dev/null 2>&1; then
        error_exit "curl is required to install the Rebecca-node CLI."
    fi
    local target="/usr/local/bin/$NEW_SERVICE_NAME"
    curl -sSL "$NODE_SCRIPT_URL" -o "$target"
    sed -i "s/^APP_NAME=.*/APP_NAME=\"$NEW_SERVICE_NAME\"/" "$target"
    chmod 755 "$target"
    log "Installed Rebecca-node CLI at $target"
}

install_node_service() {
    if ! command -v "$NEW_SERVICE_NAME" >/dev/null 2>&1; then
        warn "Rebecca-node CLI not found; skipping maintenance service installation."
        return
    fi
    if "$NEW_SERVICE_NAME" install-service >/dev/null 2>&1; then
        log "Rebecca-node maintenance service installed successfully."
    else
        warn "Failed to install maintenance service via rebecca-node CLI."
    fi
}

main() {
    require_root
    local compose_bin
    compose_bin=$(compose_binary)

    if [ -f "$OLD_APP_DIR/docker-compose.yml" ]; then
        log "Stopping existing Marzban-node stack"
        $compose_bin -f "$OLD_APP_DIR/docker-compose.yml" -p "$OLD_SERVICE_NAME" down >/dev/null 2>&1 || true
    fi

    safe_move_directory "$OLD_APP_DIR" "$NEW_APP_DIR"
    safe_move_directory "$OLD_DATA_DIR" "$NEW_DATA_DIR"

    rewrite_paths "$NEW_APP_DIR/docker-compose.yml"
    rewrite_paths "$NEW_APP_DIR/.env"

    migrate_systemd_service
    install_node_cli
    install_node_service

    log "Migration complete. You can now manage the node using 'rebecca-node'."
    log "For example: rebecca-node up"
}

main "$@"
