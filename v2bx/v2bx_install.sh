#!/bin/bash

# V2bX one-click installer (English translation of upstream script)
# Source repos remain unchanged; this is for quick node testing.

set -e

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)
DEFAULT_V2BX_VERSION="v0.4.1"

[[ $EUID -ne 0 ]] && echo -e "${red}Error:${plain} You must run this script as root.\n" && exit 1

# Detect OS
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif grep -Eqi "alpine" /etc/issue; then
    release="alpine"
elif grep -Eqi "debian" /etc/issue; then
    release="debian"
elif grep -Eqi "ubuntu" /etc/issue; then
    release="ubuntu"
elif grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux" /etc/issue; then
    release="centos"
elif grep -Eqi "debian" /proc/version; then
    release="debian"
elif grep -Eqi "ubuntu" /proc/version; then
    release="ubuntu"
elif grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux" /proc/version; then
    release="centos"
elif grep -Eqi "arch" /proc/version; then
    release="arch"
else
    echo -e "${red}Unable to detect OS version.${plain}\n" && exit 1
fi

arch=$(uname -m)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${yellow}Unknown arch, defaulting to ${arch}.${plain}"
fi
echo "Arch: ${arch}"

if [[ "$(getconf WORD_BIT)" != "32" && "$(getconf LONG_BIT)" != "64" ]]; then
    echo "32-bit systems are not supported. Please use 64-bit (x86_64)."
    exit 2
fi

# OS version check
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}Use CentOS 7 or later.${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${yellow}Note: CentOS 7 cannot run hysteria1/2 protocols.${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}Use Ubuntu 16 or later.${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}Use Debian 8 or later.${plain}\n" && exit 1
    fi
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat ca-certificates >/dev/null 2>&1
    fi
}

# status: 0 running, 1 stopped, 2 not installed
check_status() {
    if [[ ! -f /usr/local/V2bX/V2bX ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service V2bX status | awk '{print $3}')
        [[ x"${temp}" == x"started" ]] && return 0 || return 1
    else
        temp=$(systemctl status V2bX | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        [[ x"${temp}" == x"running" ]] && return 0 || return 1
    fi
}

install_V2bX() {
    if [[ -e /usr/local/V2bX/ ]]; then
        rm -rf /usr/local/V2bX/
    fi

    mkdir -p /usr/local/V2bX/
    cd /usr/local/V2bX/

    if [ $# == 0 ]; then
        last_version=$(curl -Ls "https://api.github.com/repos/wyx2685/V2bX/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ -z "$last_version" ]]; then
            echo -e "${yellow}Could not detect latest release; falling back to ${DEFAULT_V2BX_VERSION}.${plain}"
            last_version="$DEFAULT_V2BX_VERSION"
        fi
        echo -e "Installing V2bX version: ${last_version}"
        wget --no-check-certificate -N --progress=bar -O /usr/local/V2bX/V2bX-linux.zip "https://github.com/wyx2685/V2bX/releases/download/${last_version}/V2bX-linux-${arch}.zip"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Download failed. Ensure GitHub is reachable or pass a version explicitly (e.g. ${DEFAULT_V2BX_VERSION}).${plain}"
            exit 1
        fi
    else
        last_version=$1
        url="https://github.com/wyx2685/V2bX/releases/download/${last_version}/V2bX-linux-${arch}.zip"
        echo -e "Installing V2bX ${last_version}"
        wget --no-check-certificate -N --progress=bar -O /usr/local/V2bX/V2bX-linux.zip "${url}"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Download failed; please verify the version exists.${plain}"
            exit 1
        fi
    fi

    unzip V2bX-linux.zip
    rm -f V2bX-linux.zip
    chmod +x V2bX
    mkdir -p /etc/V2bX/
    cp geoip.dat /etc/V2bX/
    cp geosite.dat /etc/V2bX/

    if [[ x"${release}" == x"alpine" ]]; then
        cat <<'EOF' > /etc/init.d/V2bX
#!/sbin/openrc-run
name="V2bX"
description="V2bX"
command="/usr/local/V2bX/V2bX"
command_args="server"
command_user="root"
pidfile="/run/V2bX.pid"
command_background="yes"
depend() { need net; }
EOF
        chmod +x /etc/init.d/V2bX
        rc-update add V2bX default
        echo -e "${green}V2bX ${last_version}${plain} installed and enabled at boot."
    else
        cat <<'EOF' > /etc/systemd/system/V2bX.service
[Unit]
Description=V2bX Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/V2bX/
ExecStart=/usr/local/V2bX/V2bX server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop V2bX 2>/dev/null || true
        systemctl enable V2bX
        echo -e "${green}V2bX ${last_version}${plain} installed and enabled at boot."
    fi

    if [[ ! -f /etc/V2bX/config.json ]]; then
        cp config.json /etc/V2bX/
        echo "Fresh install. See https://v2bx.v-50.me/ for configuration guidance."
        first_install=true
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service V2bX start
        else
            systemctl start V2bX
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}V2bX restarted successfully.${plain}"
        else
            echo -e "${red}V2bX may have failed to start; check logs (V2bX log).${plain}"
        fi
        first_install=false
    fi

    for file in dns.json route.json custom_outbound.json custom_inbound.json; do
        if [[ ! -f /etc/V2bX/${file} ]]; then
            cp ${file} /etc/V2bX/
        fi
    done

    curl -o /usr/bin/V2bX -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/V2bX.sh
    chmod +x /usr/bin/V2bX
    if [ ! -L /usr/bin/v2bx ]; then
        ln -s /usr/bin/V2bX /usr/bin/v2bx
        chmod +x /usr/bin/v2bx
    fi
    cd "$cur_dir"
    rm -f install.sh
    echo ""
    echo "V2bX management commands (also usable via v2bx alias):"
    echo "------------------------------------------"
    echo "V2bX              - Show menu"
    echo "V2bX start        - Start V2bX"
    echo "V2bX stop         - Stop V2bX"
    echo "V2bX restart      - Restart V2bX"
    echo "V2bX status       - V2bX status"
    echo "V2bX enable       - Enable at boot"
    echo "V2bX disable      - Disable at boot"
    echo "V2bX log          - Tail logs"
    echo "V2bX x25519       - Generate x25519 keys"
    echo "V2bX generate     - Generate config file"
    echo "V2bX update       - Update V2bX"
    echo "V2bX update x.x.x - Update to specific version"
    echo "V2bX install      - Install V2bX"
    echo "V2bX uninstall    - Uninstall V2bX"
    echo "V2bX version      - Show version"
    echo "------------------------------------------"

    if [[ $first_install == true ]]; then
        read -rp "First install detected. Generate config file now? (y/n): " if_generate
        if [[ $if_generate == [Yy] ]]; then
            curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/initconfig.sh
            source initconfig.sh
            rm -f initconfig.sh
            generate_config_file
        fi
    fi
}

echo -e "${green}Starting installation...${plain}"
install_base
install_V2bX "$1"
