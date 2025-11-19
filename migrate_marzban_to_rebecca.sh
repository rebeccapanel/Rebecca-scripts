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

replace_text_in_file() {
    local file="$1"
    shift
    local result
    result=$(
        python - "$file" "$@" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
pairs = []
for i in range(2, len(sys.argv), 2):
    pairs.append((sys.argv[i], sys.argv[i + 1]))

text = path.read_text()
new_text = text
for old, new in pairs:
    new_text = new_text.replace(old, new)

changed = new_text != text
if changed:
    path.write_text(new_text)
print("changed" if changed else "unchanged")
PY
    )
    if [[ "$result" == "changed" ]]; then
        log "Updated references inside $file"
    else
        warn "No replacements applied to $file"
    fi
}

update_file_references() {
    local file="$1"
    if [ ! -f "$file" ]; then
        warn "$file not found. Skipping."
        return
    fi

    if [[ "$file" == *.env ]]; then
        warn "Skipping replacements inside $file to preserve database configuration. Update the addresses manually."
        return
    fi

    replace_text_in_file "$file" \
        "/var/lib/marzban" "/var/lib/rebecca" \
        "/opt/marzban" "/opt/rebecca" \
        "Marzban" "Rebecca" \
        "marzban" "rebecca"
}

migrate_systemd_service() {
    local service_path="/etc/systemd/system/${OLD_SERVICE_NAME}.service"
    if [ -f "$service_path" ]; then
        systemctl stop "${OLD_SERVICE_NAME}" >/dev/null 2>&1 || true
        replace_text_in_file "$service_path" \
            "/var/lib/marzban" "/var/lib/rebecca" \
            "/opt/marzban" "/opt/rebecca" \
            "Marzban" "Rebecca" \
            "marzban" "rebecca"
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

get_env_value() {
    local file="$1"
    local key="$2"
    if [ ! -f "$file" ]; then
        return
    fi
    local line
    line=$(grep -E "^${key}=" "$file" | tail -n 1 || true)
    if [ -z "$line" ]; then
        return
    fi
    local value
    value=${line#*=}
    value=${value%%#*}
    value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    value=${value%\"}
    value=${value#\"}
    value=${value%\'}
    value=${value#\'}
    printf "%s" "$value"
}

detect_database_service() {
    local compose_file="$1"
    if [ ! -f "$compose_file" ]; then
        return
    fi
    local current_service=""
    local in_services=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^services: ]]; then
            in_services=1
            continue
        fi
        if [ $in_services -eq 0 ]; then
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]{2}([A-Za-z0-9._-]+):[[:space:]]*$ ]]; then
            current_service="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]+image:[[:space:]]*(.+)$ ]]; then
            local image="${BASH_REMATCH[1]}"
            image=${image//\"/}
            image=${image//\'/}
            image=$(printf '%s' "$image" | xargs)
            local lower=${image,,}
            if [[ "$lower" == *"mariadb"* || "$lower" == *"mysql"* ]]; then
                printf "%s" "$current_service"
                return
            fi
        fi
    done < "$compose_file"
}

rename_database_if_needed() {
    local compose_bin="$1"
    local compose_file="$OLD_APP_DIR/docker-compose.yml"
    local env_file="$OLD_APP_DIR/.env"
    if [ ! -f "$compose_file" ] || [ ! -f "$env_file" ]; then
        return
    fi

    local current_db
    current_db=$(get_env_value "$env_file" "MARIADB_DATABASE")
    if [ -z "$current_db" ]; then
        current_db=$(get_env_value "$env_file" "MYSQL_DATABASE")
    fi
    if [ -z "$current_db" ]; then
        warn "Database name not found inside $env_file; skipping database rename."
        return
    fi

    local target_db="$NEW_SERVICE_NAME"
    if [ "$current_db" = "$target_db" ]; then
        log "Database already named '$target_db'; skipping rename."
        return
    fi

    local root_pass
    root_pass=$(get_env_value "$env_file" "MARIADB_ROOT_PASSWORD")
    if [ -z "$root_pass" ]; then
        root_pass=$(get_env_value "$env_file" "MYSQL_ROOT_PASSWORD")
    fi
    if [ -z "$root_pass" ]; then
        warn "Root database password not found in $env_file; skipping database rename."
        return
    fi

    local db_service
    db_service=$(detect_database_service "$compose_file")
    if [ -z "$db_service" ]; then
        warn "Unable to detect database service in docker-compose.yml; skipping database rename."
        return
    fi

    local temp_dump
    temp_dump=$(mktemp)
    trap 'rm -f "$temp_dump"' RETURN

    log "Exporting database '$current_db' from service '$db_service'"
    if ! $compose_bin -f "$compose_file" exec -T -e MYSQL_PWD="$root_pass" "$db_service" mysqldump -u root "$current_db" >"$temp_dump"; then
        trap - RETURN
        rm -f "$temp_dump"
        error_exit "Failed to export database '$current_db'."
    fi

    printf -v create_sql 'CREATE DATABASE IF NOT EXISTS `%s`;' "$target_db"
    log "Creating target database '$target_db'"
    if ! $compose_bin -f "$compose_file" exec -T -e MYSQL_PWD="$root_pass" "$db_service" mysql -u root -e "$create_sql"; then
        trap - RETURN
        rm -f "$temp_dump"
        error_exit "Failed to create database '$target_db'."
    fi

    log "Importing data into '$target_db'"
    if ! cat "$temp_dump" | $compose_bin -f "$compose_file" exec -T -e MYSQL_PWD="$root_pass" "$db_service" mysql -u root "$target_db"; then
        trap - RETURN
        rm -f "$temp_dump"
        error_exit "Failed to import data into '$target_db'."
    fi

    printf -v drop_sql 'DROP DATABASE `%s`;' "$current_db"
    log "Dropping legacy database '$current_db'"
    if ! $compose_bin -f "$compose_file" exec -T -e MYSQL_PWD="$root_pass" "$db_service" mysql -u root -e "$drop_sql"; then
        trap - RETURN
        rm -f "$temp_dump"
        error_exit "Failed to drop old database '$current_db'."
    fi

    trap - RETURN
    rm -f "$temp_dump"
    log "Database renamed from '$current_db' to '$target_db'."
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

restart_rebecca_panel() {
    if ! command -v rebecca >/dev/null 2>&1; then
        warn "Rebecca CLI not available; please restart the services manually."
        return
    fi
    if rebecca restart >/dev/null 2>&1; then
        log "Rebecca has been restarted successfully."
    else
        warn "Rebecca restart failed; please restart manually."
    fi
}

main() {
    require_root
    local compose_bin
    compose_bin=$(compose_binary)

    rename_database_if_needed "$compose_bin"

    if [ -f "$OLD_APP_DIR/docker-compose.yml" ]; then
        log "Stopping existing Marzban stack"
        $compose_bin -f "$OLD_APP_DIR/docker-compose.yml" -p "$OLD_SERVICE_NAME" down >/dev/null 2>&1 || true
    fi

    safe_move_directory "$OLD_APP_DIR" "$NEW_APP_DIR"
    safe_move_directory "$OLD_DATA_DIR" "$NEW_DATA_DIR"

    update_file_references "$NEW_APP_DIR/docker-compose.yml"
    update_file_references "$NEW_APP_DIR/.env"

    migrate_systemd_service
    install_rebecca_cli
    install_rebecca_service_unit
    rerun_install_service_script

    restart_rebecca_panel

    log "Migration complete. You can now manage the panel using the 'rebecca' command."
    log "For example: rebecca up"
}

main "$@"
