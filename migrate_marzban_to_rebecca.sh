#!/usr/bin/env bash
set -euo pipefail

OLD_APP_DIR="/opt/marzban"
NEW_APP_DIR="/opt/rebecca"
OLD_DATA_DIR="/var/lib/marzban"
NEW_DATA_DIR="/var/lib/rebecca"
OLD_SERVICE_NAME="marzban"
NEW_SERVICE_NAME="rebecca"
SCRIPT_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh"

log() {
    echo -e "\e[96m[rebecca-migrate]\e[0m $1"
}

warn() {
    echo -e "\e[93m[rebecca-migrate]\e[0m $1"
}

error_exit() {
    echo -e "\e[91m[rebecca-migrate]\e[0m $1"
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

backup_existing_path() {
    local target="$1"
    if [ -e "$target" ]; then
        local backup="${target}_backup_$(date +%Y%m%d%H%M%S)"
        mv "$target" "$backup"
        warn "Existing $target moved to $backup"
    fi
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

update_file_references() {
    local file="$1"
    if [ -f "$file" ]; then
        sed -i \
            -e 's#/var/lib/marzban#/var/lib/rebecca#g' \
            -e 's#/opt/marzban#/opt/rebecca#g' \
            -e 's/Marzban/Rebecca/g' \
            -e 's/marzban/rebecca/g' \
            "$file"
        log "Updated references inside $file"
    else
        warn "$file not found. Skipping."
    fi
}

ensure_database_name_updated() {
    local env_file="$NEW_APP_DIR/.env"
    local compose_file="$NEW_APP_DIR/docker-compose.yml"

    if [ -f "$env_file" ]; then
        sed -i \
            -e 's/^MYSQL_DATABASE\s*=.*/MYSQL_DATABASE=rebecca/' \
            -e 's/^MYSQL_DATABASE\s*=\s*\".*\"/MYSQL_DATABASE="rebecca"/' \
            "$env_file"
        sed -i \
            -e 's/\/marzban\"/\/rebecca"/g' \
            "$env_file"
    fi

    if [ -f "$compose_file" ]; then
        sed -i \
            -e 's/MYSQL_DATABASE:\s*marzban/MYSQL_DATABASE: rebecca/g' \
            -e 's/MYSQL_DATABASE:\s*\"marzban\"/MYSQL_DATABASE: "rebecca"/g' \
            "$compose_file"
    fi
}

migrate_systemd_service() {
    local service_path="/etc/systemd/system/${OLD_SERVICE_NAME}.service"
    if [ -f "$service_path" ]; then
        systemctl stop "${OLD_SERVICE_NAME}" >/dev/null 2>&1 || true
        sed -i \
            -e 's#/var/lib/marzban#/var/lib/rebecca#g' \
            -e 's#/opt/marzban#/opt/rebecca#g' \
            -e 's/Marzban/Rebecca/g' \
            -e 's/marzban/rebecca/g' \
            "$service_path"
        mv "$service_path" "/etc/systemd/system/${NEW_SERVICE_NAME}.service"
        systemctl daemon-reload
        systemctl enable --now "${NEW_SERVICE_NAME}.service"
        log "Updated systemd service to ${NEW_SERVICE_NAME}.service"
    else
        warn "No systemd service found for ${OLD_SERVICE_NAME}. Skipping."
    fi
}

install_rebecca_cli() {
    if ! command -v curl >/dev/null 2>&1; then
        error_exit "curl is required to install the Rebecca CLI."
    fi
    if [ -f "/usr/local/bin/rebecca" ]; then
        backup_existing_path "/usr/local/bin/rebecca"
    fi
    curl -sSL "$SCRIPT_URL" | install -m 755 /dev/stdin /usr/local/bin/rebecca
    warn "Old rebecca CLI (if any) can now be removed manually."
    log "Installed Rebecca CLI to /usr/local/bin/rebecca"
}

install_rebecca_service_unit() {
    if ! command -v rebecca >/dev/null 2>&1; then
        warn "Rebecca CLI not found; skipping maintenance service installation."
        return
    fi
    if rebecca install-service >/dev/null 2>&1; then
        log "Rebecca maintenance service installed successfully."
    else
        warn "Failed to install maintenance service via rebecca CLI."
    fi
}

rerun_install_service_script() {
    local script_path="$NEW_APP_DIR/install_service.sh"
    if [ ! -f "$script_path" ]; then
        warn "install_service.sh not found in $NEW_APP_DIR; skipping service refresh."
        return
    fi

    chmod +x "$script_path"
    (cd "$NEW_APP_DIR" && bash "$script_path") || warn "Failed to execute install_service.sh"
    systemctl enable --now rebecca.service >/dev/null 2>&1 || true
    log "Systemd service refreshed using install_service.sh"
}

main() {
    require_root
    local compose_bin
    compose_bin=$(compose_binary)

    if [ -f "$OLD_APP_DIR/docker-compose.yml" ]; then
        log "Stopping existing Marzban stack"
        $compose_bin -f "$OLD_APP_DIR/docker-compose.yml" -p "$OLD_SERVICE_NAME" down >/dev/null 2>&1 || true
    fi

    safe_move_directory "$OLD_APP_DIR" "$NEW_APP_DIR"
    safe_move_directory "$OLD_DATA_DIR" "$NEW_DATA_DIR"

    update_file_references "$NEW_APP_DIR/docker-compose.yml"
    update_file_references "$NEW_APP_DIR/.env"
    ensure_database_name_updated

    migrate_systemd_service
    install_rebecca_cli
    install_rebecca_service_unit
    rerun_install_service_script

    log "Migration complete. You can now manage the panel using the 'rebecca' command."
    log "For example: rebecca up"
}

main "$@"
