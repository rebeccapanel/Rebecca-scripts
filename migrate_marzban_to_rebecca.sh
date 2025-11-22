#!/usr/bin/env bash
set -euo pipefail

OLD_APP_DIR="/opt/marzban"
NEW_APP_DIR="/opt/rebecca"
OLD_DATA_DIR="/var/lib/marzban"
NEW_DATA_DIR="/var/lib/rebecca"
OLD_SERVICE_NAME="marzban"
NEW_SERVICE_NAME="rebecca"
SCRIPT_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh"

PANEL_IMAGE_REPO="rebeccapanel/rebecca"
DEFAULT_IMAGE_TAG="latest"
PYTHON_BIN=""

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

detect_python() {
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="python3"
    elif command -v python >/dev/null 2>&1; then
        PYTHON_BIN="python"
    else
        error_exit "python3 or python is required for rewriting configuration files."
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
        "$PYTHON_BIN" - "$file" "$@" <<'PY'
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
        warn "Skipping generic replacements for $file; use update_env_file_references instead."
        return
    fi

    replace_text_in_file "$file" \
        "/var/lib/marzban" "/var/lib/rebecca" \
        "/opt/marzban" "/opt/rebecca" \
        "Marzban" "Rebecca"
}

choose_image_tag() {
    log "Default image tag is 'latest' for $PANEL_IMAGE_REPO."
    read -rp "Do you want to use the 'dev' tag instead (${PANEL_IMAGE_REPO}:dev)? [y/N]: " answer || answer=""
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        DEFAULT_IMAGE_TAG="dev"
        log "Using image tag 'dev' (${PANEL_IMAGE_REPO}:dev)."
    else
        DEFAULT_IMAGE_TAG="latest"
        log "Using image tag 'latest' (${PANEL_IMAGE_REPO}:latest)."
    fi
}

update_compose_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        warn "$file not found. Skipping compose update."
        return
    fi

    "$PYTHON_BIN" - "$file" "$PANEL_IMAGE_REPO" "$DEFAULT_IMAGE_TAG" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
repo = sys.argv[2]
tag = sys.argv[3]
text = path.read_text()

def replace_paths(value: str) -> str:
    value = value.replace("/var/lib/marzban", "/var/lib/rebecca")
    value = value.replace("/opt/marzban", "/opt/rebecca")
    value = value.replace("Marzban", "Rebecca")
    return value

def replace_image(value: str, repo: str, tag: str) -> str:
    pattern = re.compile(
        r'(image:\s*["\']?)(?:[^/\s]+/)*marzban(?::[\w\.\-]+)?',
        re.IGNORECASE,
    )
    def _repl(match: re.Match):
        return f"{match.group(1)}{repo}:{tag}"
    return pattern.sub(_repl, value)

updated = replace_image(replace_paths(text), repo, tag)

if updated != text:
    path.write_text(updated)
PY

    log "Updated docker-compose.yml (paths + image)"
}

update_env_file_references() {
    local file="$1"
    if [ ! -f "$file" ]; then
        warn "$file not found. Skipping .env update."
        return
    fi

    "$PYTHON_BIN" - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
original = path.read_text()
lines = original.splitlines()

updated_lines = []
changed = False

for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in line:
        updated_lines.append(line)
        continue

    key, value = line.split("=", 1)

    new_value = value
    new_value = new_value.replace("/var/lib/marzban", "/var/lib/rebecca")
    new_value = new_value.replace("/opt/marzban", "/opt/rebecca")

    if new_value != value:
        changed = True

    updated_lines.append(f"{key}={new_value}")

result = "\n".join(updated_lines)
if original.endswith("\n"):
    result += "\n"

if changed:
    path.write_text(result)
PY

    log "Updated path references inside .env (without touching passwords/usernames)"
}

migrate_systemd_service() {
    local service_path="/etc/systemd/system/${OLD_SERVICE_NAME}.service"
    if [ -f "$service_path" ]; then
        systemctl stop "${OLD_SERVICE_NAME}" >/dev/null 2>&1 || true
        replace_text_in_file "$service_path" \
            "/var/lib/marzban" "/var/lib/rebecca" \
            "/opt/marzban" "/opt/rebecca" \
            "Marzban" "Rebecca"
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

restart_rebecca_panel() {
    local compose_bin="$1"
    local compose_file="$NEW_APP_DIR/docker-compose.yml"

    if command -v rebecca >/dev/null 2>&1; then
        log "All migration steps completed. Handing over to 'rebecca restart' as final step."
        log "From now on it is the same as running: rebecca restart"
        exec rebecca restart
    fi

    if [ ! -f "$compose_file" ]; then
        warn "Cannot find $compose_file to start Rebecca via docker compose."
        return
    fi

    log "Rebecca CLI not found; starting Rebecca stack using docker compose."
    if $compose_bin -f "$compose_file" -p "$NEW_SERVICE_NAME" up -d --remove-orphans; then
        log "Rebecca stack started successfully via docker compose."
    else
        warn "Docker compose up failed; please check the stack manually."
    fi
}

main() {
    require_root
    detect_python
    local compose_bin
    compose_bin=$(compose_binary)

    if [ -f "$OLD_APP_DIR/docker-compose.yml" ]; then
        log "Stopping existing Marzban stack"
        $compose_bin -f "$OLD_APP_DIR/docker-compose.yml" -p "$OLD_SERVICE_NAME" down >/dev/null 2>&1 || true
    fi

    safe_move_directory "$OLD_APP_DIR" "$NEW_APP_DIR"
    safe_move_directory "$OLD_DATA_DIR" "$NEW_DATA_DIR"

    choose_image_tag
    update_compose_file "$NEW_APP_DIR/docker-compose.yml"

    update_env_file_references "$NEW_APP_DIR/.env"

    migrate_systemd_service
    install_rebecca_cli
    install_rebecca_service_unit
    rerun_install_service_script

    log "Core migration steps are done."
    log "Now we will restart the panel."

    restart_rebecca_panel "$compose_bin"

    log "Migration complete. You can now manage the panel using the 'rebecca' command."
    log "For example: rebecca up"
}

main "$@"
