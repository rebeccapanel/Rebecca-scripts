#!/usr/bin/env bash
set -e

INSTALL_DIR="/opt"
if [ -z "$APP_NAME" ]; then
    APP_NAME="rebecca"
fi
APP_DIR="$INSTALL_DIR/$APP_NAME"
DATA_DIR="/var/lib/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
LAST_XRAY_CORES=10
CERTS_BASE="/var/lib/$APP_NAME/certs"
SERVICE_DIR="/usr/local/share/rebecca-maintenance"
SERVICE_FILE="$SERVICE_DIR/main.py"
SERVICE_REQUIREMENTS="$SERVICE_DIR/requirements.txt"
SERVICE_UNIT="/etc/systemd/system/rebecca-maint.service"
SERVICE_SOURCE_URL="https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/main.py"
SERVICE_REQUIREMENTS_URL="https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/maintenance_requirements.txt"
SERVICE_DIR_CREATED="0"
if [ -z "$REBECCA_SCRIPT_PORT" ]; then
    REBECCA_SCRIPT_PORT="3000"
fi
PARSED_DOMAINS=()

colorized_echo() {
    local color=$1
    local text=$2
    
    case $color in
        "red")
        printf "\e[91m${text}\e[0m\n";;
        "green")
        printf "\e[92m${text}\e[0m\n";;
        "yellow")
        printf "\e[93m${text}\e[0m\n";;
        "blue")
        printf "\e[94m${text}\e[0m\n";;
        "magenta")
        printf "\e[95m${text}\e[0m\n";;
        "cyan")
        printf "\e[96m${text}\e[0m\n";;
        *)
            echo "${text}"
        ;;
    esac
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}

detect_os() {
    # Detect the operating system
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
    elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}


detect_and_update_package_manager() {
    colorized_echo blue "Updating package manager"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
        $PKG_MANAGER update
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        PKG_MANAGER="yum"
        $PKG_MANAGER update -y
        $PKG_MANAGER install -y epel-release
    elif [ "$OS" == "Fedora"* ]; then
        PKG_MANAGER="dnf"
        $PKG_MANAGER update
    elif [ "$OS" == "Arch" ]; then
        PKG_MANAGER="pacman"
        $PKG_MANAGER -Sy
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        $PKG_MANAGER refresh
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_package () {
    if [ -z $PKG_MANAGER ]; then
        detect_and_update_package_manager
    fi
    
    PACKAGE=$1
    colorized_echo blue "Installing $PACKAGE"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        $PKG_MANAGER -y install "$PACKAGE"
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        $PKG_MANAGER install -y "$PACKAGE"
    elif [ "$OS" == "Fedora"* ]; then
        $PKG_MANAGER install -y "$PACKAGE"
    elif [ "$OS" == "Arch" ]; then
        $PKG_MANAGER -S --noconfirm "$PACKAGE"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

ensure_python3_venv() {
    detect_os
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PY_VER=$(python3 -c 'import sys; print(f"%s.%s" % (sys.version_info.major, sys.version_info.minor))' 2>/dev/null || echo "3")
        install_package "python${PY_VER}-venv"
    else
        install_package python3-venv
    fi
}

install_docker() {
    # Install Docker and Docker Compose using the official installation script
    colorized_echo blue "Installing Docker"
    curl -fsSL https://get.docker.com | sh
    colorized_echo green "Docker installed successfully"
}

detect_compose() {
    # Check if docker compose command exists
    if docker compose version >/dev/null 2>&1; then
        COMPOSE='docker compose'
    elif docker-compose version >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        colorized_echo red "docker compose not found"
        exit 1
    fi
}

install_rebecca_script() {
    FETCH_REPO="rebeccapanel/Rebecca-scripts"
    SCRIPT_URL="https://raw.githubusercontent.com/$FETCH_REPO/master/rebecca.sh"
    colorized_echo blue "Installing rebecca script"
    curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/rebecca
    colorized_echo green "rebecca script installed successfully"
}

install_rebecca_service() {
    check_running_as_root
    colorized_echo blue "Installing Rebecca maintenance service"

    detect_os

    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        install_package python3
    fi
    if ! command -v pip3 >/dev/null 2>&1 && ! command -v pip >/dev/null 2>&1; then
        install_package python3-pip || true
    fi

    if [ -d "$SERVICE_DIR" ]; then
        SERVICE_DIR_CREATED="0"
    else
        SERVICE_DIR_CREATED="1"
    fi
    mkdir -p "$SERVICE_DIR"
    curl -sSL "$SERVICE_SOURCE_URL" -o "$SERVICE_FILE"

    if head -n 1 "$SERVICE_FILE" | grep -qi "<!DOCTYPE\|<html"; then
        colorized_echo red "Downloaded maintenance service file is not valid Python"
        rm -f "$SERVICE_FILE"
        exit 1
    fi

    PYTHON3_BIN=$(command -v python3)
    if [ -z "$PYTHON3_BIN" ]; then
        colorized_echo red "python3 is required but was not found."
        exit 1
    fi

    VENV_DIR="$SERVICE_DIR/venv"
    colorized_echo blue "Creating maintenance virtualenv at $VENV_DIR"
    if ! "$PYTHON3_BIN" -m venv "$VENV_DIR"; then
        colorized_echo yellow "Python venv creation failed, trying to install python venv package..."
        ensure_python3_venv
        "$PYTHON3_BIN" -m venv "$VENV_DIR"
    fi
    PYTHON_BIN="$VENV_DIR/bin/python"

    trap 'cleanup_on_failure' ERR

    colorized_echo blue "Downloading maintenance requirements from $SERVICE_REQUIREMENTS_URL..."
    if curl -sSL "$SERVICE_REQUIREMENTS_URL" -o "$SERVICE_REQUIREMENTS"; then
        if head -n 1 "$SERVICE_REQUIREMENTS" | grep -qi "<!DOCTYPE\\|<html"; then
            colorized_echo yellow "Failed to download requirements (HTML received); using fallback packages"
            rm -f "$SERVICE_REQUIREMENTS"
        else
            colorized_echo green "Requirements file downloaded successfully"
        fi
    else
        colorized_echo yellow "Unable to download requirements.txt; falling back to predefined packages"
        rm -f "$SERVICE_REQUIREMENTS"
    fi

    colorized_echo blue "Installing Python dependencies inside maintenance virtualenv..."
    "$PYTHON_BIN" -m pip install --upgrade pip >/dev/null 2>&1 || true

    install_fallback_packages() {
        "$PYTHON_BIN" -m pip install --force-reinstall --no-cache-dir \
            'typing-extensions==4.12.2' \
            'pydantic-core==2.27.2' \
            'pydantic==2.10.5' \
            'fastapi==0.115.2' \
            'uvicorn[standard]==0.27.0.post1' \
            'PyYAML==6.0.2' \
            'python-multipart==0.0.9' \
            'email-validator==2.2.0' || \
        "$PYTHON_BIN" -m pip install --force-reinstall --no-cache-dir \
            'typing-extensions==4.12.2' \
            'pydantic-core==2.27.2' \
            'pydantic==2.10.5' \
            'fastapi==0.115.2' \
            'uvicorn[standard]==0.27.0.post1' \
            'PyYAML==6.0.2' \
            'python-multipart==0.0.9' \
            'email-validator==2.2.0'
    }

    if [ -f "$SERVICE_REQUIREMENTS" ]; then
        if ! $PYTHON_BIN -m pip install -r "$SERVICE_REQUIREMENTS" --break-system-packages --force-reinstall --no-cache-dir; then
            colorized_echo yellow "Failed to install using downloaded requirements. Falling back to pinned packages."
            install_fallback_packages || {
                colorized_echo red "Failed to install maintenance service dependencies."
                exit 1
            }
        fi
    else
        install_fallback_packages || {
            colorized_echo red "Failed to install maintenance service dependencies."
            exit 1
        }
    fi

    cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=Rebecca Maintenance API
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$SERVICE_DIR
Environment=REBECCA_APP_NAME=$APP_NAME
Environment=REBECCA_APP_DIR=$APP_DIR
Environment=REBECCA_DATA_DIR=$DATA_DIR
Environment=REBECCA_ENV_FILE=$ENV_FILE
Environment=REBECCA_COMPOSE_FILE=$COMPOSE_FILE
Environment=REBECCA_BACKUP_DIR=$APP_DIR/backup
Environment=REBECCA_SERVICE_NAME=$APP_NAME
Environment=REBECCA_NODE_APP_DIR=/opt/rebecca-node
Environment=REBECCA_NODE_COMPOSE_FILE=/opt/rebecca-node/docker-compose.yml
Environment=REBECCA_NODE_SERVICE_NAME=rebecca-node
Environment=REBECCA_SCRIPT_PORT=$REBECCA_SCRIPT_PORT
ExecStart=$PYTHON_BIN $SERVICE_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now rebecca-maint.service
    persist_rebecca_service_env
    trap - ERR
    colorized_echo green "Rebecca maintenance service installed and started"
}

uninstall_rebecca_service() {
    if [ -f "$SERVICE_UNIT" ]; then
        systemctl disable --now rebecca-maint.service >/dev/null 2>&1 || true
        rm -f "$SERVICE_UNIT"
        systemctl daemon-reload
    fi
    if [ -d "$SERVICE_DIR" ]; then
        rm -rf "$SERVICE_DIR"
    fi
}

cleanup_on_failure() {
    local exit_code=$?
    colorized_echo red "Installation failed, rolling back changes"
    systemctl disable --now rebecca-maint.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_UNIT"
    if [ "$SERVICE_DIR_CREATED" = "1" ]; then
        rm -rf "$SERVICE_DIR"
    fi
    exit "$exit_code"
}

trim_string() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

validate_domain_format() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        colorized_echo red "Invalid domain: $domain"
        return 1
    fi
    return 0
}

is_valid_ipv4() {
    local ip="$1"
    local IFS='.'
    read -r -a octets <<< "$ip"
    if [ ${#octets[@]} -ne 4 ]; then
        return 1
    fi
    for octet in "${octets[@]}"; do
        if [[ ! "$octet" =~ ^[0-9]+$ ]]; then
            return 1
        fi
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

is_valid_ipv6() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *:*:* ]]; then
        return 0
    fi
    return 1
}

is_valid_ip() {
    local value="$1"
    if is_valid_ipv4 "$value" || is_valid_ipv6 "$value"; then
        return 0
    fi
    return 1
}

install_ssl_dependencies() {
    detect_os
    local packages=("curl" "socat" "certbot" "openssl")
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            install_package "$pkg"
        fi
    done
}

ensure_acme_sh() {
    if [ ! -d "$HOME/.acme.sh" ]; then
        curl https://get.acme.sh | sh -s email="$1"
        if [ -f "$HOME/.bashrc" ]; then
            # shellcheck disable=SC1090
            source "$HOME/.bashrc"
        fi
    fi
}

SSL_CERT_DIR=""

issue_ssl_with_acme() {
    local email="$1"
    shift
    local domains=("$@")
    ensure_acme_sh "$email"

    local args=""
    for domain in "${domains[@]}"; do
        args+=" -d $domain"
    done

    ~/.acme.sh/acme.sh --issue --standalone $args --accountemail "$email" || return 1

    local primary="${domains[0]}"
    SSL_CERT_DIR="$CERTS_BASE/$primary"
    mkdir -p "$SSL_CERT_DIR"

    ~/.acme.sh/acme.sh --install-cert -d "$primary" \
        --key-file "$SSL_CERT_DIR/privkey.pem" \
        --fullchain-file "$SSL_CERT_DIR/fullchain.pem" || return 1

    echo "provider=acme" > "$SSL_CERT_DIR/.metadata"
    echo "email=$email" >> "$SSL_CERT_DIR/.metadata"
    echo "domains=${domains[*]}" >> "$SSL_CERT_DIR/.metadata"
    echo "issued_at=$(date -u +%s)" >> "$SSL_CERT_DIR/.metadata"
    return 0
}

issue_ssl_with_certbot() {
    local email="$1"
    shift
    local domains=("$@")

    local args=""
    for domain in "${domains[@]}"; do
        args+=" -d $domain"
    done

    certbot certonly --standalone $args --non-interactive --agree-tos --email "$email" || return 1

    local primary="${domains[0]}"
    SSL_CERT_DIR="$CERTS_BASE/$primary"
    mkdir -p "$SSL_CERT_DIR"

    cat "/etc/letsencrypt/live/$primary/privkey.pem" > "$SSL_CERT_DIR/privkey.pem"
    cat "/etc/letsencrypt/live/$primary/fullchain.pem" > "$SSL_CERT_DIR/fullchain.pem"

    echo "provider=certbot" > "$SSL_CERT_DIR/.metadata"
    echo "email=$email" >> "$SSL_CERT_DIR/.metadata"
    echo "domains=${domains[*]}" >> "$SSL_CERT_DIR/.metadata"
    echo "issued_at=$(date -u +%s)" >> "$SSL_CERT_DIR/.metadata"
    return 0
}

issue_ssl_self_signed_ip() {
    local email="$1"
    shift
    local ips=("$@")

    if [ ${#ips[@]} -eq 0 ]; then
        colorized_echo red "At least one IP address is required for self-signed SSL."
        return 1
    fi

    detect_os
    if ! command -v openssl >/dev/null 2>&1; then
        install_package openssl
    fi

    local primary="${ips[0]}"
    local cert_id
    cert_id=$(echo "$primary" | tr ':' '_')
    SSL_CERT_DIR="$CERTS_BASE/$cert_id"
    mkdir -p "$SSL_CERT_DIR"

    local openssl_conf
    openssl_conf=$(mktemp)
    {
        echo "[ req ]"
        echo "default_bits = 2048"
        echo "prompt = no"
        echo "default_md = sha256"
        echo "req_extensions = v3_req"
        echo "distinguished_name = dn"
        echo
        echo "[ dn ]"
        echo "CN = $primary"
        echo
        echo "[ v3_req ]"
        echo "subjectAltName = @alt_names"
        echo
        echo "[ alt_names ]"
        local idx=1
        for ip in "${ips[@]}"; do
            echo "IP.$idx = $ip"
            idx=$((idx + 1))
        done
    } > "$openssl_conf"

    if ! openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
        -keyout "$SSL_CERT_DIR/privkey.pem" \
        -out "$SSL_CERT_DIR/fullchain.pem" \
        -config "$openssl_conf" >/dev/null 2>&1; then
        rm -f "$openssl_conf"
        colorized_echo red "Failed to generate self-signed certificate."
        return 1
    fi
    rm -f "$openssl_conf"

    echo "provider=self-signed" > "$SSL_CERT_DIR/.metadata"
    echo "email=$email" >> "$SSL_CERT_DIR/.metadata"
    echo "domains=${ips[*]}" >> "$SSL_CERT_DIR/.metadata"
    echo "issued_at=$(date -u +%s)" >> "$SSL_CERT_DIR/.metadata"
    return 0
}

set_env_value() {
    local key="$1"
    local value="$2"
    value=$(echo "$value" | sed 's/^"//;s/"$//')
    mkdir -p "$(dirname "$ENV_FILE")"
    touch "$ENV_FILE"
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = \"${value}\"|" "$ENV_FILE"
    else
        echo "${key} = \"${value}\"" >> "$ENV_FILE"
    fi
}

persist_rebecca_service_env() {
    local host="${REBECCA_SCRIPT_HOST:-127.0.0.1}"
    local port="${REBECCA_SCRIPT_PORT:-3000}"
    local allowed="${REBECCA_SCRIPT_ALLOWED_HOSTS:-127.0.0.1,::1,localhost}"
    set_env_value "REBECCA_SCRIPT_HOST" "$host"
    set_env_value "REBECCA_SCRIPT_PORT" "$port"
    set_env_value "REBECCA_MAINT_PORT" "$port"
    set_env_value "REBECCA_SCRIPT_ALLOWED_HOSTS" "$allowed"
}

sync_ssl_env_paths() {
    local cert_dir="$1"
    local ca_type="${2:-public}"
    set_env_value "UVICORN_SSL_CERTFILE" "$cert_dir/fullchain.pem"
    set_env_value "UVICORN_SSL_KEYFILE" "$cert_dir/privkey.pem"
    set_env_value "UVICORN_SSL_CA_TYPE" "$ca_type"
}

perform_ssl_issue() {
    local email="$1"
    local preferred="${2:-auto}"
    shift 2
    local domains=("$@")
    local provider_used=""
    local has_ip=0
    local has_domain=0

    if [ ${#domains[@]} -eq 0 ]; then
        colorized_echo red "At least one domain is required for SSL issuance."
        return 1
    fi

    for d in "${domains[@]}"; do
        if is_valid_ip "$d"; then
            has_ip=1
        else
            has_domain=1
        fi
    done

    if [ "$has_ip" -eq 1 ] && [ "$has_domain" -eq 1 ]; then
        colorized_echo red "Mixing IP addresses and domains is not supported in one certificate request."
        return 1
    fi

    install_ssl_dependencies
    mkdir -p "$CERTS_BASE"

    if [ "$has_ip" -eq 1 ] || [ "$preferred" = "self-signed" ]; then
        if [ "$has_domain" -eq 1 ]; then
            colorized_echo red "self-signed provider is only allowed with IP addresses."
            return 1
        fi
        issue_ssl_self_signed_ip "$email" "${domains[@]}" || return 1
        provider_used="self-signed"
        sync_ssl_env_paths "$SSL_CERT_DIR" "self-signed"
        colorized_echo green "Self-signed SSL certificate generated at $SSL_CERT_DIR for IP(s): ${domains[*]}"
        
        if is_rebecca_installed; then
            detect_compose
            if is_rebecca_up; then
                colorized_echo blue "Restarting Rebecca to apply SSL configuration..."
                down_rebecca
                up_rebecca
                colorized_echo green "Rebecca restarted with SSL configuration"
            fi
        fi
        
        return 0
    fi

    if [ "$preferred" = "acme" ]; then
        issue_ssl_with_acme "$email" "${domains[@]}" || return 1
        provider_used="acme"
    elif [ "$preferred" = "certbot" ]; then
        issue_ssl_with_certbot "$email" "${domains[@]}" || return 1
        provider_used="certbot"
    else
        if issue_ssl_with_acme "$email" "${domains[@]}"; then
            provider_used="acme"
        else
            colorized_echo yellow "acme.sh issuance failed, falling back to certbot..."
            issue_ssl_with_certbot "$email" "${domains[@]}" || return 1
            provider_used="certbot"
        fi
    fi

    sync_ssl_env_paths "$SSL_CERT_DIR"
    colorized_echo green "SSL certificate installed at $SSL_CERT_DIR using $provider_used"
    
    # Check if Rebecca is installed and running, then restart to apply SSL changes
    if is_rebecca_installed; then
        detect_compose
        if is_rebecca_up; then
            colorized_echo blue "Restarting Rebecca to apply SSL configuration..."
            down_rebecca
            up_rebecca
            colorized_echo green "Rebecca restarted with SSL configuration"
        fi
    fi
    
    return 0
}

parse_domains_input() {
    local input="$1"
    PARSED_DOMAINS=()
    PARSED_IS_IP=0
    local has_ip=0
    local has_domain=0
    IFS=',' read -ra raw_domains <<< "$input"
    for entry in "${raw_domains[@]}"; do
        local domain
        domain=$(trim_string "$entry")
        if [ -z "$domain" ]; then
            continue
        fi
        if is_valid_ip "$domain"; then
            has_ip=1
        else
            validate_domain_format "$domain" || return 1
            has_domain=1
        fi
        PARSED_DOMAINS+=("$domain")
    done
    if [ ${#PARSED_DOMAINS[@]} -eq 0 ]; then
        colorized_echo red "No valid domains provided."
        return 1
    fi
    if [ "$has_ip" -eq 1 ] && [ "$has_domain" -eq 1 ]; then
        colorized_echo red "Cannot mix IP addresses and domains in one request."
        return 1
    fi
    if [ "$has_ip" -eq 1 ]; then
        PARSED_IS_IP=1
    fi
}

prompt_ssl_setup() {
    read -p "Do you want to configure SSL certificates now? (y/N): " ssl_answer
    if [[ ! "$ssl_answer" =~ ^[Yy]$ ]]; then
        return
    fi
    read -p "Enter email for certificate notifications: " ssl_email
    read -p "Enter domain(s) separated by comma: " ssl_domains
    if ! ssl_command issue --email "$ssl_email" --domains "$ssl_domains" --non-interactive; then
        colorized_echo yellow "SSL setup skipped due to input/issuance error. You can retry with: rebecca ssl issue"
    fi
}

ssl_issue() {
    local email=""
    local domains_input=""
    local provider="auto"
    local interactive=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email=*)
                email="${1#*=}"
                shift
                ;;
            --email)
                email="$2"
                shift 2
                ;;
            --domains=*)
                domains_input="${1#*=}"
                shift
                ;;
            --domains)
                domains_input="$2"
                shift 2
                ;;
            --provider=*)
                provider="${1#*=}"
                shift
                ;;
            --provider)
                provider="$2"
                shift 2
                ;;
            --non-interactive)
                interactive=false
                shift
                ;;
            *)
                colorized_echo red "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [ "$interactive" = true ]; then
        if [ -z "$email" ]; then
            read -p "Enter email address: " email
        fi
        if [ -z "$domains_input" ]; then
            read -p "Enter domain(s) separated by comma: " domains_input
        fi
    else
        if [ -z "$email" ] || [ -z "$domains_input" ]; then
            colorized_echo red "Email and domains are required when using non-interactive mode."
            return 1
        fi
    fi

    parse_domains_input "$domains_input" || return 1
    perform_ssl_issue "$email" "$provider" "${PARSED_DOMAINS[@]}"
}

get_domain_from_env() {
    if [ ! -f "$ENV_FILE" ]; then
        return
    fi
    local line
    line=$(grep "^UVICORN_SSL_CERTFILE" "$ENV_FILE" | tail -n 1 | cut -d'=' -f2-)
    line=$(echo "$line" | tr -d ' "')
    if [ -z "$line" ]; then
        return
    fi
    basename "$(dirname "$line")"
}

ssl_renew() {
    local target_domain=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain=*)
                target_domain="${1#*=}"
                shift
                ;;
            --domain)
                target_domain="$2"
                shift 2
                ;;
            *)
                colorized_echo red "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [ -z "$target_domain" ]; then
        target_domain=$(get_domain_from_env)
    fi

    if [ -z "$target_domain" ]; then
        colorized_echo red "Unable to detect domain. Please specify --domain example.com"
        return 1
    fi

    local metadata="$CERTS_BASE/$target_domain/.metadata"
    if [ ! -f "$metadata" ]; then
        colorized_echo red "Metadata not found for domain $target_domain"
        return 1
    fi

    local provider email domains_line
    provider=$(grep '^provider=' "$metadata" | cut -d'=' -f2-)
    email=$(grep '^email=' "$metadata" | cut -d'=' -f2-)
    domains_line=$(grep '^domains=' "$metadata" | cut -d'=' -f2-)

    if [ -z "$email" ] || [ -z "$domains_line" ]; then
        colorized_echo red "Metadata is incomplete for $target_domain"
        return 1
    fi

    read -ra stored_domains <<< "$domains_line"
    perform_ssl_issue "$email" "$provider" "${stored_domains[@]}" || return 1
    colorized_echo green "SSL certificate renewed for $target_domain"
    
    # Note: perform_ssl_issue already restarts Rebecca if needed
}

ssl_command() {
    local action="$1"
    shift || true

    case "$action" in
        issue)
            ssl_issue "$@"
            ;;
        renew)
            ssl_renew "$@"
            ;;
        *)
            colorized_echo blue "Usage: rebecca ssl <issue|renew> [options]"
            ;;
    esac
}

is_rebecca_installed() {
    if [ -d $APP_DIR ]; then
        return 0
    else
        return 1
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'i386' | 'i686')
                ARCH='32'
            ;;
            'amd64' | 'x86_64')
                ARCH='64'
            ;;
            'armv5tel')
                ARCH='arm32-v5'
            ;;
            'armv6l')
                ARCH='arm32-v6'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv7' | 'armv7l')
                ARCH='arm32-v7a'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv8' | 'aarch64')
                ARCH='arm64-v8a'
            ;;
            'mips')
                ARCH='mips32'
            ;;
            'mipsle')
                ARCH='mips32le'
            ;;
            'mips64')
                ARCH='mips64'
                lscpu | grep -q "Little Endian" && ARCH='mips64le'
            ;;
            'mips64le')
                ARCH='mips64le'
            ;;
            'ppc64')
                ARCH='ppc64'
            ;;
            'ppc64le')
                ARCH='ppc64le'
            ;;
            'riscv64')
                ARCH='riscv64'
            ;;
            's390x')
                ARCH='s390x'
            ;;
            *)
                echo "error: The architecture is not supported."
                exit 1
            ;;
        esac
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

send_backup_to_telegram() {
    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value"
            else
                colorized_echo yellow "Skipping invalid line in .env: $key=$value"
            fi
        done < "$ENV_FILE"
    else
        colorized_echo red "Environment file (.env) not found."
        exit 1
    fi

    if [ "$BACKUP_SERVICE_ENABLED" != "true" ]; then
        colorized_echo yellow "Backup service is not enabled. Skipping Telegram upload."
        return
    fi

    local server_ip=$(curl -s ifconfig.me || echo "Unknown IP")
    local latest_backup=$(ls -t "$APP_DIR/backup" | head -n 1)
    local backup_path="$APP_DIR/backup/$latest_backup"

    if [ ! -f "$backup_path" ]; then
        colorized_echo red "No backups found to send."
        return
    fi

    local backup_size=$(du -m "$backup_path" | cut -f1)
    local split_dir="/tmp/rebecca_backup_split"
    local is_single_file=true

    mkdir -p "$split_dir"

    if [ "$backup_size" -gt 49 ]; then
        colorized_echo yellow "Backup is larger than 49MB. Splitting the archive..."
        split -b 49M "$backup_path" "$split_dir/part_"
        is_single_file=false
    else
        cp "$backup_path" "$split_dir/part_aa"
    fi


    local backup_time=$(date "+%Y-%m-%d %H:%M:%S %Z")


    for part in "$split_dir"/*; do
        local part_name=$(basename "$part")
        local custom_filename="backup_${part_name}.tar.gz"
        local caption="📦 *Backup Information*\n🌐 *Server IP*: \`${server_ip}\`\n📁 *Backup File*: \`${custom_filename}\`\n⏰ *Backup Time*: \`${backup_time}\`"
        curl -s -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$part;filename=$custom_filename" \
            -F caption="$(echo -e "$caption" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g')" \
            -F parse_mode="MarkdownV2" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument" >/dev/null 2>&1 && \
        colorized_echo green "Backup part $custom_filename successfully sent to Telegram." || \
        colorized_echo red "Failed to send backup part $custom_filename to Telegram."
    done

    rm -rf "$split_dir"
}

send_backup_error_to_telegram() {
    local error_messages=$1
    local log_file=$2
    local server_ip=$(curl -s ifconfig.me || echo "Unknown IP")
    local error_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local message="⚠️ *Backup Error Notification*\n"
    message+="🌐 *Server IP*: \`${server_ip}\`\n"
    message+="❌ *Errors*:\n\`${error_messages//_/\\_}\`\n"
    message+="⏰ *Time*: \`${error_time}\`"


    message=$(echo -e "$message" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g;s/(/\\(/g;s/)/\\)/g')

    local max_length=1000
    if [ ${#message} -gt $max_length ]; then
        message="${message:0:$((max_length - 50))}...\n\`[Message truncated]\`"
    fi


    curl -s -X POST "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendMessage" \
        -d chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
        -d parse_mode="MarkdownV2" \
        -d text="$message" >/dev/null 2>&1 && \
    colorized_echo green "Backup error notification sent to Telegram." || \
    colorized_echo red "Failed to send error notification to Telegram."


    if [ -f "$log_file" ]; then
        response=$(curl -s -w "%{http_code}" -o /tmp/tg_response.json \
            -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$log_file;filename=backup_error.log" \
            -F caption="📜 *Backup Error Log* - ${error_time}" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument")

        http_code="${response:(-3)}"
        if [ "$http_code" -eq 200 ]; then
            colorized_echo green "Backup error log sent to Telegram."
        else
            colorized_echo red "Failed to send backup error log to Telegram. HTTP code: $http_code"
            cat /tmp/tg_response.json
        fi
    else
        colorized_echo red "Log file not found: $log_file"
    fi
}





backup_service() {
    local telegram_bot_key=""
    local telegram_chat_id=""
    local cron_schedule=""
    local interval_hours=""

    colorized_echo blue "====================================="
    colorized_echo blue "      Welcome to Backup Service      "
    colorized_echo blue "====================================="

    if grep -q "BACKUP_SERVICE_ENABLED=true" "$ENV_FILE"; then
        telegram_bot_key=$(awk -F'=' '/^BACKUP_TELEGRAM_BOT_KEY=/ {print $2}' "$ENV_FILE")
        telegram_chat_id=$(awk -F'=' '/^BACKUP_TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")
        cron_schedule=$(awk -F'=' '/^BACKUP_CRON_SCHEDULE=/ {print $2}' "$ENV_FILE" | tr -d '"')

        if [[ "$cron_schedule" == "0 0 * * *" ]]; then
            interval_hours=24
        else
            interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
        fi

        colorized_echo green "====================================="
        colorized_echo green "Current Backup Configuration:"
        colorized_echo cyan "Telegram Bot API Key: $telegram_bot_key"
        colorized_echo cyan "Telegram Chat ID: $telegram_chat_id"
        colorized_echo cyan "Backup Interval: Every $interval_hours hour(s)"
        colorized_echo green "====================================="
        echo "Choose an option:"
        echo "1. Reconfigure Backup Service"
        echo "2. Remove Backup Service"
        echo "3. Exit"
        read -p "Enter your choice (1-3): " user_choice

        case $user_choice in
            1)
                colorized_echo yellow "Starting reconfiguration..."
                remove_backup_service
                ;;
            2)
                colorized_echo yellow "Removing Backup Service..."
                remove_backup_service
                return
                ;;
            3)
                colorized_echo yellow "Exiting..."
                return
                ;;
            *)
                colorized_echo red "Invalid choice. Exiting."
                return
                ;;
        esac
    else
        colorized_echo yellow "No backup service is currently configured."
    fi

    while true; do
        printf "Enter your Telegram bot API key: "
        read telegram_bot_key
        if [[ -n "$telegram_bot_key" ]]; then
            break
        else
            colorized_echo red "API key cannot be empty. Please try again."
        fi
    done

    while true; do
        printf "Enter your Telegram chat ID: "
        read telegram_chat_id
        if [[ -n "$telegram_chat_id" ]]; then
            break
        else
            colorized_echo red "Chat ID cannot be empty. Please try again."
        fi
    done

    while true; do
        printf "Set up the backup interval in hours (1-24):\n"
        read interval_hours

        if ! [[ "$interval_hours" =~ ^[0-9]+$ ]]; then
            colorized_echo red "Invalid input. Please enter a valid number."
            continue
        fi

        if [[ "$interval_hours" -eq 24 ]]; then
            cron_schedule="0 0 * * *"
            colorized_echo green "Setting backup to run daily at midnight."
            break
        fi

        if [[ "$interval_hours" -ge 1 && "$interval_hours" -le 23 ]]; then
            cron_schedule="0 */$interval_hours * * *"
            colorized_echo green "Setting backup to run every $interval_hours hour(s)."
            break
        else
            colorized_echo red "Invalid input. Please enter a number between 1-24."
        fi
    done

    sed -i '/^BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/^BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    {
        echo ""
        echo "# Backup service configuration"
        echo "BACKUP_SERVICE_ENABLED=true"
        echo "BACKUP_TELEGRAM_BOT_KEY=$telegram_bot_key"
        echo "BACKUP_TELEGRAM_CHAT_ID=$telegram_chat_id"
        echo "BACKUP_CRON_SCHEDULE=\"$cron_schedule\""
    } >> "$ENV_FILE"

    colorized_echo green "Backup service configuration saved in $ENV_FILE."

    local backup_command="$(which bash) -c '$APP_NAME backup'"
    add_cron_job "$cron_schedule" "$backup_command"

    colorized_echo green "Backup service successfully configured."
    if [[ "$interval_hours" -eq 24 ]]; then
        colorized_echo cyan "Backups will be sent to Telegram daily (every 24 hours at midnight)."
    else
        colorized_echo cyan "Backups will be sent to Telegram every $interval_hours hour(s)."
    fi
    colorized_echo green "====================================="
}


add_cron_job() {
    local schedule="$1"
    local command="$2"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null > "$temp_cron" || true
    grep -v "$command" "$temp_cron" > "${temp_cron}.tmp" && mv "${temp_cron}.tmp" "$temp_cron"
    echo "$schedule $command # rebecca-backup-service" >> "$temp_cron"
    
    if crontab "$temp_cron"; then
        colorized_echo green "Cron job successfully added."
    else
        colorized_echo red "Failed to add cron job. Please check manually."
    fi
    rm -f "$temp_cron"
}

remove_backup_service() {
    colorized_echo red "in process..."


    sed -i '/^# Backup service configuration/d' "$ENV_FILE"
    sed -i '/BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null > "$temp_cron"

    sed -i '/# rebecca-backup-service/d' "$temp_cron"

    if crontab "$temp_cron"; then
        colorized_echo green "Backup service task removed from crontab."
    else
        colorized_echo red "Failed to update crontab. Please check manually."
    fi

    rm -f "$temp_cron"

    colorized_echo green "Backup service has been removed."
}

backup_command() {
    local backup_dir="$APP_DIR/backup"
    local temp_dir="/tmp/rebecca_backup"
    local timestamp=$(date +"%Y%m%d%H%M%S")
    local backup_file="$backup_dir/backup_$timestamp.tar.gz"
    local error_messages=()
    local log_file="/var/log/rebecca_backup_error.log"
    > "$log_file"
    echo "Backup Log - $(date)" > "$log_file"

    if ! command -v rsync >/dev/null 2>&1; then
        detect_os
        install_package rsync
    fi

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"
    mkdir -p "$temp_dir"

    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value"
            else
                echo "Skipping invalid line in .env: $key=$value" >> "$log_file"
            fi
        done < "$ENV_FILE"
    else
        error_messages+=("Environment file (.env) not found.")
        echo "Environment file (.env) not found." >> "$log_file"
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        exit 1
    fi

    local db_type=""
    local sqlite_file=""
    if grep -q "image: mariadb" "$COMPOSE_FILE"; then
        db_type="mariadb"
        container_name=$(docker compose -f "$COMPOSE_FILE" ps -q mariadb || echo "mariadb")

    elif grep -q "image: mysql" "$COMPOSE_FILE"; then
        db_type="mysql"
        container_name=$(docker compose -f "$COMPOSE_FILE" ps -q mysql || echo "mysql")

    elif grep -q "SQLALCHEMY_DATABASE_URL = .*sqlite" "$ENV_FILE"; then
        db_type="sqlite"
        sqlite_file=$(grep -Po '(?<=SQLALCHEMY_DATABASE_URL = "sqlite:////).*"' "$ENV_FILE" | tr -d '"')
        if [[ ! "$sqlite_file" =~ ^/ ]]; then
            sqlite_file="/$sqlite_file"
        fi

    fi

    if [ -n "$db_type" ]; then
        echo "Database detected: $db_type" >> "$log_file"
        case $db_type in
            mariadb)
                if ! docker exec "$container_name" mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases --ignore-database=mysql --ignore-database=performance_schema --ignore-database=information_schema --ignore-database=sys --events --triggers > "$temp_dir/db_backup.sql" 2>>"$log_file"; then
                    error_messages+=("MariaDB dump failed.")
                fi
                ;;
            mysql)
                if ! docker exec "$container_name" mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" rebecca --events --triggers  > "$temp_dir/db_backup.sql" 2>>"$log_file"; then
                    error_messages+=("MySQL dump failed.")
                fi
                ;;
            sqlite)
                if [ -f "$sqlite_file" ]; then
                    if ! cp "$sqlite_file" "$temp_dir/db_backup.sqlite" 2>>"$log_file"; then
                        error_messages+=("Failed to copy SQLite database.")
                    fi
                else
                    error_messages+=("SQLite database file not found at $sqlite_file.")
                fi
                ;;
        esac
    fi

    cp "$APP_DIR/.env" "$temp_dir/" 2>>"$log_file"
    cp "$APP_DIR/docker-compose.yml" "$temp_dir/" 2>>"$log_file"
    rsync -av --exclude 'xray-core' --exclude 'mysql' "$DATA_DIR/" "$temp_dir/rebecca_data/" >>"$log_file" 2>&1

    if ! tar -czf "$backup_file" -C "$temp_dir" .; then
        error_messages+=("Failed to create backup archive.")
        echo "Failed to create backup archive." >> "$log_file"
    fi

    rm -rf "$temp_dir"

    if [ ${#error_messages[@]} -gt 0 ]; then
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        return
    fi
    colorized_echo green "Backup created: $backup_file"
    send_backup_to_telegram "$backup_file"
}



get_xray_core() {
    identify_the_operating_system_and_architecture
    clear

    validate_version() {
        local version="$1"
        
        local response=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$version")
        if echo "$response" | grep -q '"message": "Not Found"'; then
            echo "invalid"
        else
            echo "valid"
        fi
    }

    print_menu() {
        clear
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;32m      Xray-core Installer     \033[0m"
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;33mAvailable Xray-core versions:\033[0m"
        for ((i=0; i<${#versions[@]}; i++)); do
            echo -e "\033[1;34m$((i + 1)):\033[0m ${versions[i]}"
        done
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;35mM:\033[0m Enter a version manually"
        echo -e "\033[1;31mQ:\033[0m Quit"
        echo -e "\033[1;32m==============================\033[0m"
    }

    latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=$LAST_XRAY_CORES")

    versions=($(echo "$latest_releases" | grep -oP '"tag_name": "\K(.*?)(?=")'))

    while true; do
        print_menu
        read -p "Choose a version to install (1-${#versions[@]}), or press M to enter manually, Q to quit: " choice
        
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#versions[@]}" ]; then
            choice=$((choice - 1))
            selected_version=${versions[choice]}
            break
        elif [ "$choice" == "M" ] || [ "$choice" == "m" ]; then
            while true; do
                read -p "Enter the version manually (e.g., v1.2.3): " custom_version
                if [ "$(validate_version "$custom_version")" == "valid" ]; then
                    selected_version="$custom_version"
                    break 2
                else
                    echo -e "\033[1;31mInvalid version or version does not exist. Please try again.\033[0m"
                fi
            done
        elif [ "$choice" == "Q" ] || [ "$choice" == "q" ]; then
            echo -e "\033[1;31mExiting.\033[0m"
            exit 0
        else
            echo -e "\033[1;31mInvalid choice. Please try again.\033[0m"
            sleep 2
        fi
    done

    echo -e "\033[1;32mSelected version $selected_version for installation.\033[0m"

    # Check if the required packages are installed
    if ! command -v unzip >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package unzip
    fi
    if ! command -v wget >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package wget
    fi

    mkdir -p $DATA_DIR/xray-core
    cd $DATA_DIR/xray-core

    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"

    echo -e "\033[1;33mDownloading Xray-core version ${selected_version}...\033[0m"
    wget -q -O "${xray_filename}" "${xray_download_url}"

    echo -e "\033[1;33mExtracting Xray-core...\033[0m"
    unzip -o "${xray_filename}" >/dev/null 2>&1
    rm "${xray_filename}"
}

get_current_xray_core_version() {
    XRAY_BINARY="$DATA_DIR/xray-core/xray"
    if [ -f "$XRAY_BINARY" ]; then
        version_output=$("$XRAY_BINARY" -version 2>/dev/null)
        if [ $? -eq 0 ]; then
            version=$(echo "$version_output" | head -n1 | awk '{print $2}')
            echo "$version"
            return
        fi
    fi

    CONTAINER_NAME="$APP_NAME"
    if docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
        version_output=$(docker exec "$CONTAINER_NAME" xray -version 2>/dev/null)
        if [ $? -eq 0 ]; then
            version=$(echo "$version_output" | head -n1 | awk '{print $2}')
            echo "$version (in container)"
            return
        fi
    fi

    echo "Not installed"
}

# Function to update the Rebecca Main core
update_core_command() {
    check_running_as_root
    get_xray_core
    # Change the Rebecca core
    xray_executable_path="XRAY_EXECUTABLE_PATH=\"/var/lib/rebecca/xray-core/xray\""
    
    echo "Changing the Rebecca core..."
    # Check if the XRAY_EXECUTABLE_PATH string already exists in the .env file
    if ! grep -q "^XRAY_EXECUTABLE_PATH=" "$ENV_FILE"; then
        # If the string does not exist, add it
        echo "${xray_executable_path}" >> "$ENV_FILE"
    else
        # Update the existing XRAY_EXECUTABLE_PATH line
        sed -i "s~^XRAY_EXECUTABLE_PATH=.*~${xray_executable_path}~" "$ENV_FILE"
    fi
    
    # Restart Rebecca
    colorized_echo red "Restarting Rebecca..."
    if restart_command -n >/dev/null 2>&1; then
        colorized_echo green "Rebecca successfully restarted!"
    else
        colorized_echo red "Rebecca restart failed!"
    fi
    colorized_echo blue "Installation of Xray-core version $selected_version completed."
}

install_rebecca() {
    local rebecca_version=$1
    local database_type=$2
    # Fetch releases
    FILES_URL_PREFIX="https://raw.githubusercontent.com/rebeccapanel/Rebecca/master"
    
    mkdir -p "$DATA_DIR"
    mkdir -p "$APP_DIR"
    
    colorized_echo blue "Setting up docker-compose.yml"
    docker_file_path="$APP_DIR/docker-compose.yml"
    
    if [ "$database_type" == "mariadb" ]; then
        # Generate docker-compose.yml with MariaDB content
        cat > "$docker_file_path" <<EOF
services:
  rebecca:
    image: rebeccapanel/rebecca:${rebecca_version}
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/rebecca:/var/lib/rebecca
      - /var/lib/rebecca/logs:/var/lib/rebecca-node
    depends_on:
      mariadb:
        condition: service_healthy

  mariadb:
    image: mariadb:lts
    env_file: .env
    network_mode: host
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_ROOT_HOST: '%'
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    command:
      - --bind-address=127.0.0.1                  # Restricts access to localhost for increased security
      - --character_set_server=utf8mb4            # Sets UTF-8 character set for full Unicode support
      - --collation_server=utf8mb4_unicode_ci     # Defines collation for Unicode
      - --host-cache-size=0                       # Disables host cache to prevent DNS issues
      - --innodb-open-files=1024                  # Sets the limit for InnoDB open files
      - --innodb-buffer-pool-size=256M            # Allocates buffer pool size for InnoDB
      - --binlog_expire_logs_seconds=1209600      # Sets binary log expiration to 14 days (2 weeks)
      - --innodb-log-file-size=64M                # Sets InnoDB log file size to balance log retention and performance
      - --innodb-log-files-in-group=2             # Uses two log files to balance recovery and disk I/O
      - --innodb-doublewrite=0                    # Disables doublewrite buffer (reduces disk I/O; may increase data loss risk)
      - --general_log=0                           # Disables general query log to reduce disk usage
      - --slow_query_log=1                        # Enables slow query log for identifying performance issues
      - --slow_query_log_file=/var/lib/mysql/slow.log # Logs slow queries for troubleshooting
      - --long_query_time=2                       # Defines slow query threshold as 2 seconds
    volumes:
      - /var/lib/rebecca/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      start_interval: 3s
      interval: 10s
      timeout: 5s
      retries: 3
EOF
        echo "----------------------------"
        colorized_echo red "Using MariaDB as database"
        echo "----------------------------"
        colorized_echo green "File generated at $APP_DIR/docker-compose.yml"

        # Modify .env file
        colorized_echo blue "Fetching .env file"
        curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"

        # Comment out the SQLite line
        sed -i 's~^\(SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/rebecca/db.sqlite3"\)~#\1~' "$APP_DIR/.env"


        # Add the MySQL connection string
        #echo -e '\nSQLALCHEMY_DATABASE_URL = "mysql+pymysql://rebecca:password@127.0.0.1:3306/rebecca"' >> "$APP_DIR/.env"

        sed -i 's/^# \(XRAY_JSON = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's~\(XRAY_JSON = \).*~\1"/var/lib/rebecca/xray_config.json"~' "$APP_DIR/.env"


        prompt_for_rebecca_password
        MYSQL_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        
        echo "" >> "$ENV_FILE"
        echo "" >> "$ENV_FILE"
        echo "# Database configuration" >> "$ENV_FILE"
        echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >> "$ENV_FILE"
        echo "MYSQL_DATABASE=rebecca" >> "$ENV_FILE"
        echo "MYSQL_USER=rebecca" >> "$ENV_FILE"
        echo "MYSQL_PASSWORD=$MYSQL_PASSWORD" >> "$ENV_FILE"
        
        SQLALCHEMY_DATABASE_URL="mysql+pymysql://rebecca:${MYSQL_PASSWORD}@127.0.0.1:3306/rebecca"
        
        echo "" >> "$ENV_FILE"
        echo "# SQLAlchemy Database URL" >> "$ENV_FILE"
        echo "SQLALCHEMY_DATABASE_URL=\"$SQLALCHEMY_DATABASE_URL\"" >> "$ENV_FILE"
        
        colorized_echo green "File saved in $APP_DIR/.env"

    elif [ "$database_type" == "mysql" ]; then
        # Generate docker-compose.yml with MySQL content
        cat > "$docker_file_path" <<EOF
services:
  rebecca:
    image: rebeccapanel/rebecca:${rebecca_version}
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/rebecca:/var/lib/rebecca
      - /var/lib/rebecca/logs:/var/lib/rebecca-node
    depends_on:
      mysql:
        condition: service_healthy

  mysql:
    image: mysql:lts
    env_file: .env
    network_mode: host
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_ROOT_HOST: '%'
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    command:
      - --mysqlx=OFF                             # Disables MySQL X Plugin to save resources if X Protocol isn't used
      - --bind-address=127.0.0.1                  # Restricts access to localhost for increased security
      - --character_set_server=utf8mb4            # Sets UTF-8 character set for full Unicode support
      - --collation_server=utf8mb4_unicode_ci     # Defines collation for Unicode
      - --log-bin=mysql-bin                       # Enables binary logging for point-in-time recovery
      - --binlog_expire_logs_seconds=1209600      # Sets binary log expiration to 14 days
      - --host-cache-size=0                       # Disables host cache to prevent DNS issues
      - --innodb-open-files=1024                  # Sets the limit for InnoDB open files
      - --innodb-buffer-pool-size=256M            # Allocates buffer pool size for InnoDB
      - --innodb-log-file-size=64M                # Sets InnoDB log file size to balance log retention and performance
      - --innodb-log-files-in-group=2             # Uses two log files to balance recovery and disk I/O
      - --general_log=0                           # Disables general query log for lower disk usage
      - --slow_query_log=1                        # Enables slow query log for performance analysis
      - --slow_query_log_file=/var/lib/mysql/slow.log # Logs slow queries for troubleshooting
      - --long_query_time=2                       # Defines slow query threshold as 2 seconds
    volumes:
      - /var/lib/rebecca/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-u", "rebecca", "--password=\${MYSQL_PASSWORD}"]
      start_period: 5s
      interval: 5s
      timeout: 5s
      retries: 55
      
EOF
        echo "----------------------------"
        colorized_echo red "Using MySQL as database"
        echo "----------------------------"
        colorized_echo green "File generated at $APP_DIR/docker-compose.yml"

        # Modify .env file
        colorized_echo blue "Fetching .env file"
        curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"

        # Comment out the SQLite line
        sed -i 's~^\(SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/rebecca/db.sqlite3"\)~#\1~' "$APP_DIR/.env"


        # Add the MySQL connection string
        #echo -e '\nSQLALCHEMY_DATABASE_URL = "mysql+pymysql://rebecca:password@127.0.0.1:3306/rebecca"' >> "$APP_DIR/.env"

        sed -i 's/^# \(XRAY_JSON = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's~\(XRAY_JSON = \).*~\1"/var/lib/rebecca/xray_config.json"~' "$APP_DIR/.env"


        prompt_for_rebecca_password
        MYSQL_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        
        echo "" >> "$ENV_FILE"
        echo "" >> "$ENV_FILE"
        echo "# Database configuration" >> "$ENV_FILE"
        echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >> "$ENV_FILE"
        echo "MYSQL_DATABASE=rebecca" >> "$ENV_FILE"
        echo "MYSQL_USER=rebecca" >> "$ENV_FILE"
        echo "MYSQL_PASSWORD=$MYSQL_PASSWORD" >> "$ENV_FILE"
        
        SQLALCHEMY_DATABASE_URL="mysql+pymysql://rebecca:${MYSQL_PASSWORD}@127.0.0.1:3306/rebecca"
        
        echo "" >> "$ENV_FILE"
        echo "# SQLAlchemy Database URL" >> "$ENV_FILE"
        echo "SQLALCHEMY_DATABASE_URL=\"$SQLALCHEMY_DATABASE_URL\"" >> "$ENV_FILE"
        
        colorized_echo green "File saved in $APP_DIR/.env"

    else
        echo "----------------------------"
        colorized_echo red "Using SQLite as database"
        echo "----------------------------"
        colorized_echo blue "Fetching compose file"
        curl -sL "$FILES_URL_PREFIX/docker-compose.yml" -o "$docker_file_path"

        # Install requested version
        if [ "$rebecca_version" == "latest" ]; then
            yq -i '.services.rebecca.image = "rebeccapanel/rebecca:latest"' "$docker_file_path"
        else
            yq -i ".services.rebecca.image = \"rebeccapanel/rebecca:${rebecca_version}\"" "$docker_file_path"
        fi
        echo "Installing $rebecca_version version"
        colorized_echo green "File saved in $APP_DIR/docker-compose.yml"


        colorized_echo blue "Fetching .env file"
        curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"

        sed -i 's/^# \(XRAY_JSON = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's/^# \(SQLALCHEMY_DATABASE_URL = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's~\(XRAY_JSON = \).*~\1"/var/lib/rebecca/xray_config.json"~' "$APP_DIR/.env"
        sed -i 's~\(SQLALCHEMY_DATABASE_URL = \).*~\1"sqlite:////var/lib/rebecca/db.sqlite3"~' "$APP_DIR/.env"







        
        colorized_echo green "File saved in $APP_DIR/.env"
    fi
    
    colorized_echo blue "Fetching xray config file"
    curl -sL "$FILES_URL_PREFIX/xray_config.json" -o "$DATA_DIR/xray_config.json"
    colorized_echo green "File saved in $DATA_DIR/xray_config.json"
    
    colorized_echo green "Rebecca's files downloaded successfully"
}

up_rebecca() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" up -d --remove-orphans
}

follow_rebecca_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs -f
}

status_command() {
    
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        echo -n "Status: "
        colorized_echo red "Not Installed"
        exit 1
    fi
    
    detect_compose
    
    if ! is_rebecca_up; then
        echo -n "Status: "
        colorized_echo blue "Down"
        exit 1
    fi
    
    echo -n "Status: "
    colorized_echo green "Up"
    
    json=$($COMPOSE -f $COMPOSE_FILE ps -a --format=json)
    services=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .Service')
    states=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .State')
    # Print out the service names and statuses
    for i in $(seq 0 $(expr $(echo $services | wc -w) - 1)); do
        service=$(echo $services | cut -d' ' -f $(expr $i + 1))
        state=$(echo $states | cut -d' ' -f $(expr $i + 1))
        echo -n "- $service: "
        if [ "$state" == "running" ]; then
            colorized_echo green $state
        else
            colorized_echo red $state
        fi
    done
}


prompt_for_rebecca_password() {
    colorized_echo cyan "This password will be used to access the database and should be strong."
    colorized_echo cyan "If you do not enter a custom password, a secure 20-character password will be generated automatically."

    # Запрашиваем ввод пароля
    read -p "Enter the password for the rebecca user (or press Enter to generate a secure default password): " MYSQL_PASSWORD

    # Генерация 20-значного пароля, если пользователь оставил поле пустым
    if [ -z "$MYSQL_PASSWORD" ]; then
        MYSQL_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        colorized_echo green "A secure password has been generated automatically."
    fi
    colorized_echo green "This password will be recorded in the .env file for future use."

    # Пауза 3 секунды перед продолжением
    sleep 3
}

install_command() {
    check_running_as_root

    if [[ "${1:-}" == "service" ]]; then
        shift
        install_rebecca_service "$@"
        return
    fi

    # Default values
    database_type="sqlite"
    rebecca_version="latest"
    rebecca_version_set="false"

    # Parse options
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --database)
                database_type="$2"
                shift 2
            ;;
            --dev)
                if [[ "$rebecca_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                rebecca_version="dev"
                rebecca_version_set="true"
                shift
            ;;
            --version)
                if [[ "$rebecca_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                rebecca_version="$2"
                rebecca_version_set="true"
                shift 2
            ;;
            *)
                echo "Unknown option: $1"
                exit 1
            ;;
        esac
    done

    # Check if rebecca is already installed
    if is_rebecca_installed; then
        colorized_echo red "Rebecca is already installed at $APP_DIR"
        read -p "Do you want to override the previous installation? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted installation"
            exit 1
        fi
    fi
    detect_os
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi
    if ! command -v yq >/dev/null 2>&1; then
        install_yq
    fi
    detect_compose
    install_rebecca_script
    install_rebecca_service
    # Function to check if a version exists in the GitHub releases
    check_version_exists() {
        local version=$1
        repo_url="https://api.github.com/repos/rebeccapanel/Rebecca/releases"
        if [ "$version" == "latest" ] || [ "$version" == "dev" ]; then
            return 0
        fi
        
        # Fetch the release data from GitHub API
        response=$(curl -s "$repo_url")
        
        # Check if the response contains the version tag
        if echo "$response" | jq -e ".[] | select(.tag_name == \"${version}\")" > /dev/null; then
            return 0
        else
            return 1
        fi
    }
    # Check if the version is valid and exists
    if [[ "$rebecca_version" == "latest" || "$rebecca_version" == "dev" || "$rebecca_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if check_version_exists "$rebecca_version"; then
            install_rebecca "$rebecca_version" "$database_type"
            echo "Installing $rebecca_version version"
        else
            echo "Version $rebecca_version does not exist. Please enter a valid version (e.g. v0.5.2)"
            exit 1
        fi
    else
        echo "Invalid version format. Please enter a valid version (e.g. v0.5.2)"
        exit 1
    fi
    prompt_ssl_setup
    up_rebecca
    follow_rebecca_logs
}

install_yq() {
    if command -v yq &>/dev/null; then
        colorized_echo green "yq is already installed."
        return
    fi

    identify_the_operating_system_and_architecture

    local base_url="https://github.com/mikefarah/yq/releases/latest/download"
    local yq_binary=""

    case "$ARCH" in
        '64' | 'x86_64')
            yq_binary="yq_linux_amd64"
            ;;
        'arm32-v7a' | 'arm32-v6' | 'arm32-v5' | 'armv7l')
            yq_binary="yq_linux_arm"
            ;;
        'arm64-v8a' | 'aarch64')
            yq_binary="yq_linux_arm64"
            ;;
        '32' | 'i386' | 'i686')
            yq_binary="yq_linux_386"
            ;;
        *)
            colorized_echo red "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    local yq_url="${base_url}/${yq_binary}"
    colorized_echo blue "Downloading yq from ${yq_url}..."

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        colorized_echo yellow "Neither curl nor wget is installed. Attempting to install curl."
        install_package curl || {
            colorized_echo red "Failed to install curl. Please install curl or wget manually."
            exit 1
        }
    fi


    if command -v curl &>/dev/null; then
        if curl -L "$yq_url" -o /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using curl. Please check your internet connection."
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if wget -O /usr/local/bin/yq "$yq_url"; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using wget. Please check your internet connection."
            exit 1
        fi
    fi


    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
    fi


    hash -r

    if command -v yq &>/dev/null; then
        colorized_echo green "yq is ready to use."
    elif [ -x "/usr/local/bin/yq" ]; then

        colorized_echo yellow "yq is installed at /usr/local/bin/yq but not found in PATH."
        colorized_echo yellow "You can add /usr/local/bin to your PATH environment variable."
    else
        colorized_echo red "yq installation failed. Please try again or install manually."
        exit 1
    fi
}


down_rebecca() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" down
}



show_rebecca_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs
}

rebecca_cli() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" exec -e CLI_PROG_NAME="rebecca cli" rebecca rebecca-cli "$@"
}


is_rebecca_up() {
    if [ -z "$($COMPOSE -f $COMPOSE_FILE ps -q -a)" ]; then
        return 1
    else
        return 0
    fi
}

uninstall_command() {
    check_running_as_root
    local app_exists=0
    if is_rebecca_installed; then
        app_exists=1
    fi

    local service_exists=0
    if [ -f "$SERVICE_UNIT" ]; then
        service_exists=1
    fi

    if [ "$app_exists" -eq 0 ] && [ "$service_exists" -eq 0 ]; then
        colorized_echo red "Rebecca's not installed!"
        exit 1
    fi

    read -p "Do you really want to uninstall Rebecca? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Aborted"
        exit 1
    fi

    if [ "$app_exists" -eq 1 ]; then
        detect_compose
        if is_rebecca_up; then
            down_rebecca
        fi
    fi
    uninstall_rebecca_script
    uninstall_rebecca_service

    if [ "$app_exists" -eq 1 ]; then
        uninstall_rebecca
        uninstall_rebecca_docker_images

        read -p "Do you want to remove Rebecca's data files too ($DATA_DIR)? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo green "Rebecca uninstalled successfully"
        else
            uninstall_rebecca_data_files
            colorized_echo green "Rebecca uninstalled successfully"
        fi
    else
        colorized_echo green "Rebecca maintenance service and script removed"
    fi
}

uninstall_rebecca_script() {
    if [ -f "/usr/local/bin/rebecca" ]; then
        colorized_echo yellow "Removing rebecca script"
        rm "/usr/local/bin/rebecca"
    fi
}

uninstall_rebecca() {
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}

uninstall_rebecca_docker_images() {
    images=$(docker images | grep rebecca | awk '{print $3}')
    
    if [ -n "$images" ]; then
        colorized_echo yellow "Removing Docker images of Rebecca"
        for image in $images; do
            if docker rmi "$image" >/dev/null 2>&1; then
                colorized_echo yellow "Image $image removed"
            fi
        done
    fi
}

uninstall_rebecca_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}

restart_command() {
    help() {
        colorized_echo red "Usage: rebecca restart [options]"
        echo
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs)
                no_logs=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "Rebecca's not installed!"
        exit 1
    fi
    
    detect_compose
    
    down_rebecca
    up_rebecca
    if [ "$no_logs" = false ]; then
        follow_rebecca_logs
    fi
    colorized_echo green "Rebecca successfully restarted!"
}
logs_command() {
    help() {
        colorized_echo red "Usage: rebecca logs [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-follow   do not show follow logs"
    }
    
    local no_follow=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-follow)
                no_follow=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "Rebecca's not installed!"
        exit 1
    fi
    
    detect_compose
    
    if ! is_rebecca_up; then
        colorized_echo red "Rebecca is not up."
        exit 1
    fi
    
    if [ "$no_follow" = true ]; then
        show_rebecca_logs
    else
        follow_rebecca_logs
    fi
}

down_command() {
    
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "Rebecca's not installed!"
        exit 1
    fi
    
    detect_compose
    
    if ! is_rebecca_up; then
        colorized_echo red "Rebecca's already down"
        exit 1
    fi
    
    down_rebecca
}

cli_command() {
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "Rebecca's not installed!"
        exit 1
    fi
    
    detect_compose
    
    if ! is_rebecca_up; then
        colorized_echo red "Rebecca is not up."
        exit 1
    fi
    
    rebecca_cli "$@"
}

up_command() {
    help() {
        colorized_echo red "Usage: rebecca up [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs)
                no_logs=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "Rebecca's not installed!"
        exit 1
    fi
    
    detect_compose
    
    if is_rebecca_up; then
        colorized_echo red "Rebecca's already up"
        exit 1
    fi
    
    up_rebecca
    if [ "$no_logs" = false ]; then
        follow_rebecca_logs
    fi
}

update_command() {
    check_running_as_root
    # Check if rebecca is installed
    if ! is_rebecca_installed; then
        colorized_echo red "Rebecca's not installed!"
        exit 1
    fi
    
    detect_compose
    
    update_rebecca_script
    colorized_echo blue "Pulling latest version"
    update_rebecca
    
    colorized_echo blue "Restarting Rebecca's services"
    down_rebecca
    up_rebecca
    
    colorized_echo blue "Rebecca updated successfully"
}

update_rebecca_script() {
    FETCH_REPO="rebeccapanel/Rebecca-scripts"
    SCRIPT_URL="https://raw.githubusercontent.com/$FETCH_REPO/master/rebecca.sh"
    colorized_echo blue "Updating rebecca script"
    curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/rebecca
    colorized_echo green "rebecca script updated successfully"
}

update_rebecca_service() {
    check_running_as_root

    colorized_echo blue "Updating Rebecca maintenance service"

    if [ ! -d "$SERVICE_DIR" ]; then
        colorized_echo yellow "Service directory not found; installing service instead"
        install_rebecca_service
        return
    fi

    detect_os
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi

    if ! curl -sSL "$SERVICE_SOURCE_URL" -o "$SERVICE_FILE"; then
        colorized_echo red "Failed to download maintenance main.py"
        exit 1
    fi
    if head -n 1 "$SERVICE_FILE" | grep -qi "<!DOCTYPE\|<html"; then
        colorized_echo red "Downloaded maintenance service file is not valid Python"
        rm -f "$SERVICE_FILE"
        exit 1
    fi

    if curl -sSL "$SERVICE_REQUIREMENTS_URL" -o "$SERVICE_REQUIREMENTS"; then
        if head -n 1 "$SERVICE_REQUIREMENTS" | grep -qi "<!DOCTYPE\|<html"; then
            colorized_echo yellow "requirements.txt is HTML, keeping existing deps"
            rm -f "$SERVICE_REQUIREMENTS"
        fi
    else
        rm -f "$SERVICE_REQUIREMENTS"
    fi

    VENV_DIR="$SERVICE_DIR/venv"
    PYTHON_BIN="$VENV_DIR/bin/python"

    if [ ! -x "$PYTHON_BIN" ]; then
        colorized_echo yellow "Virtualenv missing, reinstalling maintenance service..."
        install_rebecca_service
        return
    fi

    "$PYTHON_BIN" -m pip install --upgrade pip >/dev/null 2>&1 || true

    if [ -f "$SERVICE_REQUIREMENTS" ]; then
        "$PYTHON_BIN" -m pip install -r "$SERVICE_REQUIREMENTS" --force-reinstall --no-cache-dir || true
    fi

    systemctl daemon-reload
    systemctl restart rebecca-maint.service
    colorized_echo green "Rebecca maintenance service updated and restarted"
}

update_rebecca() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" pull
}

check_editor() {
    if [ -z "$EDITOR" ]; then
        if command -v nano >/dev/null 2>&1; then
            EDITOR="nano"
            elif command -v vi >/dev/null 2>&1; then
            EDITOR="vi"
        else
            detect_os
            install_package nano
            EDITOR="nano"
        fi
    fi
}


edit_command() {
    detect_os
    check_editor
    if [ -f "$COMPOSE_FILE" ]; then
        $EDITOR "$COMPOSE_FILE"
    else
        colorized_echo red "Compose file not found at $COMPOSE_FILE"
        exit 1
    fi
}

edit_env_command() {
    detect_os
    check_editor
    if [ -f "$ENV_FILE" ]; then
        $EDITOR "$ENV_FILE"
    else
        colorized_echo red "Environment file not found at $ENV_FILE"
        exit 1
    fi
}

service_status_command() {
    if [ ! -f "$SERVICE_UNIT" ]; then
        colorized_echo red "Rebecca maintenance service is not installed"
        colorized_echo yellow "Install it with: rebecca install-service"
        exit 1
    fi

    colorized_echo blue "================================"
    colorized_echo cyan "Rebecca Maintenance Service Status"
    colorized_echo blue "================================"
    systemctl status rebecca-maint.service --no-pager
}

service_logs_command() {
    if [ ! -f "$SERVICE_UNIT" ]; then
        colorized_echo red "Rebecca maintenance service is not installed"
        colorized_echo yellow "Install it with: rebecca install-service"
        exit 1
    fi

    colorized_echo blue "Showing Rebecca maintenance service logs (Ctrl+C to exit)..."
    journalctl -u rebecca-maint.service -f
}

usage() {
    local script_name="${0##*/}"
    colorized_echo blue "=============================="
    colorized_echo magenta "           Rebecca Help"
    colorized_echo blue "=============================="
    colorized_echo cyan "Usage:"
    echo "  ${script_name} [command]"
    echo

    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up              $(tput sgr0)– Start services"
    colorized_echo yellow "  down            $(tput sgr0)– Stop services"
    colorized_echo yellow "  restart         $(tput sgr0)– Restart services"
    colorized_echo yellow "  status          $(tput sgr0)– Show status"
    colorized_echo yellow "  logs            $(tput sgr0)– Show logs"
    colorized_echo yellow "  cli             $(tput sgr0)– Rebecca CLI"
    colorized_echo yellow "  install         $(tput sgr0)- Install Rebecca"
    colorized_echo yellow "  install service $(tput sgr0)- Install only the maintenance service"
    colorized_echo yellow "  update          $(tput sgr0)- Update to latest version"
    colorized_echo yellow "  uninstall       $(tput sgr0)– Uninstall Rebecca"
    colorized_echo yellow "  install-script  $(tput sgr0)- Install Rebecca script"
    colorized_echo yellow "  update-script   $(tput sgr0)- Update Rebecca CLI script"
    colorized_echo yellow "  update-service  $(tput sgr0)- Update maintenance service binary"
    colorized_echo yellow "  uninstall-service  $(tput sgr0)- Uninstall maintenance service"
    colorized_echo yellow "  service-status  $(tput sgr0)- Show maintenance service status"
    colorized_echo yellow "  service-logs    $(tput sgr0)- Show maintenance service logs"
    colorized_echo yellow "  backup          $(tput sgr0)- Manual backup launch"
    colorized_echo yellow "  backup-service  $(tput sgr0)– Rebecca Backupservice to backup to TG, and a new job in crontab"
    colorized_echo yellow "  core-update     $(tput sgr0)- Update/Change Xray core"
    colorized_echo yellow "  edit            $(tput sgr0)- Edit docker-compose.yml (via nano or vi editor)"
    colorized_echo yellow "  edit-env        $(tput sgr0)- Edit environment file (via nano or vi editor)"
    colorized_echo yellow "  ssl             $(tput sgr0)- Issue or renew SSL certificates"
    colorized_echo yellow "  help            $(tput sgr0)- Show this help message"
    
    
    echo
    colorized_echo cyan "Directories:"
    colorized_echo magenta "  App directory: $APP_DIR"
    colorized_echo magenta "  Data directory: $DATA_DIR"
    echo
    current_version=$(get_current_xray_core_version)
    colorized_echo cyan "Current Xray-core version: $current_version"
    colorized_echo blue "================================"
    echo
}

case "$1" in
    up)
        shift; up_command "$@";;
    down)
        shift; down_command "$@";;
    restart)
        shift; restart_command "$@";;
    status)
        shift; status_command "$@";;
    logs)
        shift; logs_command "$@";;
    cli)
        shift; cli_command "$@";;
    backup)
        shift; backup_command "$@";;
    backup-service)
        shift; backup_service "$@";;
    install)
        shift; install_command "$@";;
    install-service)
        shift; install_rebecca_service "$@";;
    update)
        shift; update_command "$@";;
    uninstall)
        shift; uninstall_command "$@";;
    install-script)
        shift; install_rebecca_script "$@";;
    update-script)
        shift; install_rebecca_script "$@";;
    update-service)
        shift; update_rebecca_service "$@";;
    uninstall-service)
        shift; uninstall_rebecca_service "$@";;
    core-update)
        shift; update_core_command "$@";;
    ssl)
        shift; ssl_command "$@";;
    edit)
        shift; edit_command "$@";;
    edit-env)
        shift; edit_env_command "$@";;
    service-status)
        shift; service_status_command "$@";;
    service-logs)
        shift; service_logs_command "$@";;
    help|*)
        usage;;
esac
