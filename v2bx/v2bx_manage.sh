#!/bin/bash

# V2bX management helper (English translation of upstream V2bX.sh)
# Uses upstream GitHub URLs; adjust later if hosting changes.

set -e

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${red}Error:${plain} Run as root.\n" && exit 1

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
    echo -e "${red}Could not detect OS.${plain}\n" && exit 1
fi

# OS version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    [[ ${os_version} -le 6 ]] && echo -e "${red}Use CentOS 7+.${plain}\n" && exit 1
    [[ ${os_version} -eq 7 ]] && echo -e "${yellow}Note: CentOS 7 cannot run hysteria1/2 protocols.${plain}\n"
elif [[ x"${release}" == x"ubuntu" ]]; then
    [[ ${os_version} -lt 16 ]] && echo -e "${red}Use Ubuntu 16+.${plain}\n" && exit 1
elif [[ x"${release}" == x"debian" ]]; then
    [[ ${os_version} -lt 8 ]] && echo -e "${red}Use Debian 8+.${plain}\n" && exit 1
fi

check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"
    else
        echo "0"
    fi
}

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [default $2]: " temp
        [[ -z "${temp}" ]] && temp=$2
    else
        read -rp "$1 [y/n]: " temp
    fi
    [[ "${temp}" =~ ^[Yy]$ ]] && return 0 || return 1
}

confirm_restart() {
    confirm "Restart V2bX now?" "y" && restart || show_menu
}

before_show_menu() {
    echo && echo -n -e "${yellow}Press Enter to return to menu: ${plain}" && read temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    if [[ $# == 0 ]]; then
        echo && read -rp "Specify version (blank = latest): " version
    else
        version=$2
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh) $version
    if [[ $? == 0 ]]; then
        echo -e "${green}Update complete. V2bX restarted; check logs with 'V2bX log'.${plain}"
        exit
    fi
    [[ $# == 0 ]] && before_show_menu
}

config() {
    echo "V2bX will attempt to restart after config changes."
    vi /etc/V2bX/config.json
    sleep 2
    restart
    check_status
    case $? in
        0) echo -e "V2bX status: ${green}running${plain}" ;;
        1)
            echo -e "V2bX not running or restart failed. View logs? [Y/n]" && echo
            read -e -rp "(default: y):" yn
            [[ -z ${yn} ]] && yn="y"
            [[ ${yn} == [Yy] ]] && show_log
            ;;
        2) echo -e "V2bX status: ${red}not installed${plain}" ;;
    esac
}

uninstall() {
    confirm "Uninstall V2bX?" "n" || { [[ $# == 0 ]] && show_menu; return 0; }
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX stop || true
        rc-update del V2bX || true
        rm -f /etc/init.d/V2bX
    else
        systemctl stop V2bX || true
        systemctl disable V2bX || true
        rm -f /etc/systemd/system/V2bX.service
        systemctl daemon-reload || true
        systemctl reset-failed || true
    fi
    rm -rf /etc/V2bX/ /usr/local/V2bX/
    echo ""
    echo -e "Uninstalled. To remove this helper, run ${green}rm /usr/bin/V2bX -f${plain}"
    echo ""
    [[ $# == 0 ]] && before_show_menu
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}V2bX is already running. Use restart if needed.${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service V2bX start
        else
            systemctl start V2bX
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}V2bX started. Use 'V2bX log' to view logs.${plain}"
        else
            echo -e "${red}V2bX may have failed to start; check logs.${plain}"
        fi
    fi
    [[ $# == 0 ]] && before_show_menu
}

stop() {
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX stop
    else
        systemctl stop V2bX
    fi
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}V2bX stopped.${plain}"
    else
        echo -e "${red}Stop may have failed; check logs.${plain}"
    fi
    [[ $# == 0 ]] && before_show_menu
}

restart() {
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX restart
    else
        systemctl restart V2bX
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}V2bX restarted. Use 'V2bX log' for details.${plain}"
    else
        echo -e "${red}V2bX may have failed to restart; check logs.${plain}"
    fi
    [[ $# == 0 ]] && before_show_menu
}

status() {
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX status
    else
        systemctl status V2bX --no-pager -l
    fi
    [[ $# == 0 ]] && before_show_menu
}

enable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update add V2bX
    else
        systemctl enable V2bX
    fi
    [[ $? == 0 ]] && echo -e "${green}Enabled at boot.${plain}" || echo -e "${red}Failed to enable.${plain}"
    [[ $# == 0 ]] && before_show_menu
}

disable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update del V2bX
    else
        systemctl disable V2bX
    fi
    [[ $? == 0 ]] && echo -e "${green}Disabled at boot.${plain}" || echo -e "${red}Failed to disable.${plain}"
    [[ $# == 0 ]] && before_show_menu
}

show_log() {
    if [[ x"${release}" == x"alpine" ]]; then
        echo -e "${red}Log tailing not supported on Alpine via this helper.${plain}\n" && exit 1
    else
        journalctl -u V2bX.service -e --no-pager -f
    fi
    [[ $# == 0 ]] && before_show_menu
}

install_bbr() {
    bash <(curl -L -s https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh)
}

update_shell() {
    wget -O /usr/bin/V2bX -N --no-check-certificate https://raw.githubusercontent.com/wyx2685/V2bX-script/master/V2bX.sh
    if [[ $? != 0 ]]; then
        echo ""
        echo -e "${red}Failed to download script; check GitHub connectivity.${plain}"
        before_show_menu
    else
        chmod +x /usr/bin/V2bX
        echo -e "${green}Script updated. Re-run to use the new version.${plain}" && exit 0
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

check_enabled() {
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(rc-update show | grep V2bX)
        [[ -z "${temp}" ]] && return 1 || return 0
    else
        temp=$(systemctl is-enabled V2bX)
        [[ x"${temp}" == x"enabled" ]] && return 0 || return 1
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        echo -e "${red}V2bX is already installed; do not reinstall.${plain}"
        [[ $# == 0 ]] && before_show_menu
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        echo -e "${red}Please install V2bX first.${plain}"
        [[ $# == 0 ]] && before_show_menu
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "V2bX status: ${green}running${plain}"
            show_enable_status
            ;;
        1)
            echo -e "V2bX status: ${yellow}stopped${plain}"
            show_enable_status
            ;;
        2)
            echo -e "V2bX status: ${red}not installed${plain}"
            ;;
    esac
}

show_enable_status() {
    check_enabled
    [[ $? == 0 ]] && echo -e "Autostart: ${green}enabled${plain}" || echo -e "Autostart: ${red}disabled${plain}"
}

generate_x25519_key() {
    echo -n "Generating x25519 keys: "
    /usr/local/V2bX/V2bX x25519
    echo ""
    [[ $# == 0 ]] && before_show_menu
}

show_V2bX_version() {
    echo -n "V2bX version: "
    /usr/local/V2bX/V2bX version
    echo ""
    [[ $# == 0 ]] && before_show_menu
}

add_node_config() {
    echo -e "${green}Choose core type:${plain}"
    echo -e "${green}1. xray${plain}"
    echo -e "${green}2. singbox${plain}"
    echo -e "${green}3. hysteria2${plain}"
    read -rp "Enter choice: " core_type
    if [ "$core_type" == "1" ]; then
        core="xray"; core_xray=true
    elif [ "$core_type" == "2" ]; then
        core="sing"; core_sing=true
    elif [ "$core_type" == "3" ]; then
        core="hysteria2"; core_hysteria2=true
    else
        echo "Invalid choice. Use 1/2/3."
        return
    fi

    while true; do
        read -rp "Enter Node ID: " NodeID
        [[ "$NodeID" =~ ^[0-9]+$ ]] && break || echo "Enter a positive integer."
    done

    if [ "$core_hysteria2" = true ] && [ "$core_xray" = false ] && [ "$core_sing" = false ]; then
        NodeType="hysteria2"
    else
        echo -e "${yellow}Choose node protocol:${plain}"
        echo -e "${green}1. Shadowsocks${plain}"
        echo -e "${green}2. Vless${plain}"
        echo -e "${green}3. Vmess${plain}"
        if [ "$core_sing" == true ]; then
            echo -e "${green}4. Hysteria${plain}"
            echo -e "${green}5. Hysteria2${plain}"
        fi
        if [ "$core_hysteria2" == true ] && [ "$core_sing" = false ]; then
            echo -e "${green}5. Hysteria2${plain}"
        fi
        echo -e "${green}6. Trojan${plain}"
        if [ "$core_sing" == true ]; then
            echo -e "${green}7. Tuic${plain}"
            echo -e "${green}8. AnyTLS${plain}"
        fi
        read -rp "Enter choice: " NodeType
        case "$NodeType" in
            1 ) NodeType="shadowsocks" ;;
            2 ) NodeType="vless" ;;
            3 ) NodeType="vmess" ;;
            4 ) NodeType="hysteria" ;;
            5 ) NodeType="hysteria2" ;;
            6 ) NodeType="trojan" ;;
            7 ) NodeType="tuic" ;;
            8 ) NodeType="anytls" ;;
            * ) NodeType="shadowsocks" ;;
        esac
    fi

    fastopen=true
    if [ "$NodeType" == "vless" ]; then
        read -rp "Is this a Reality node? (y/n): " isreality
    elif [[ "$NodeType" == "hysteria" || "$NodeType" == "hysteria2" || "$NodeType" == "tuic" || "$NodeType" == "anytls" ]]; then
        fastopen=false
        istls="y"
    fi

    if [[ "$isreality" != "y" && "$isreality" != "Y" && "$istls" != "y" ]]; then
        read -rp "Configure TLS? (y/n): " istls
    fi

    certmode="none"
    certdomain="example.com"
    if [[ "$isreality" != "y" && "$isreality" != "Y" && ( "$istls" == "y" || "$istls" == "Y" ) ]]; then
        echo -e "${yellow}Choose certificate mode:${plain}"
        echo -e "${green}1. http (auto request; domain must resolve)${plain}"
        echo -e "${green}2. dns (auto request; needs DNS provider API)${plain}"
        echo -e "${green}3. self (self-signed or existing files)${plain}"
        read -rp "Enter choice: " certmode
        case "$certmode" in
            1 ) certmode="http" ;;
            2 ) certmode="dns" ;;
            3 ) certmode="self" ;;
        esac
        read -rp "Enter certificate domain (example.com): " certdomain
        if [ "$certmode" != "http" ]; then
            echo -e "${red}Edit config manually if needed, then restart V2bX.${plain}"
        fi
    fi

    ipv6_support=$(check_ipv6_support)
    listen_ip="0.0.0.0"
    [[ "$ipv6_support" -eq 1 ]] && listen_ip="::"

    if [ "$core_type" == "1" ]; then
        node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "0.0.0.0",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "EnableProxyProtocol": false,
            "EnableUot": true,
            "EnableTFO": true,
            "DNSType": "UseIPv4",
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/V2bX/fullchain.cer",
                "KeyFile": "/etc/V2bX/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        },
EOF
)
    elif [ "$core_type" == "2" ]; then
        node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "$listen_ip",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "TCPFastOpen": $fastopen,
            "SniffEnabled": true,
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/V2bX/fullchain.cer",
                "KeyFile": "/etc/V2bX/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        },
EOF
)
    elif [ "$core_type" == "3" ]; then
        node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Hysteria2ConfigPath": "/etc/V2bX/hy2config.yaml",
            "Timeout": 30,
            "ListenIP": "",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "/etc/V2bX/fullchain.cer",
                "KeyFile": "/etc/V2bX/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        },
EOF
)
    fi
    nodes_config+=("$node_config")
}

generate_config_file() {
    echo -e "${yellow}V2bX config generator${plain}"
    echo -e "${red}Notes:${plain}"
    echo -e "${red}1) Experimental${plain}"
    echo -e "${red}2) Output: /etc/V2bX/config.json${plain}"
    echo -e "${red}3) Backup saved to /etc/V2bX/config.json.bak${plain}"
    echo -e "${red}4) TLS is partially supported${plain}"
    echo -e "${red}5) Generated config includes auditing. Continue? (y/n)${plain}"
    read -rp "Enter choice: " continue_prompt
    if [[ "$continue_prompt" =~ ^[Nn][Oo]?$ ]]; then
        exit 0
    fi

    nodes_config=()
    first_node=true
    core_xray=false
    core_sing=false
    core_hysteria2=false
    fixed_api_info=false

    while true; do
        if [ "$first_node" = true ]; then
            read -rp "Panel URL (https://example.com): " ApiHost
            read -rp "Panel API Key: " ApiKey
            read -rp "Reuse this URL/key for all nodes? (y/n): " fixed_api
            if [[ "$fixed_api" =~ ^[Yy]$ ]]; then
                fixed_api_info=true
                echo -e "${green}Using fixed API info.${plain}"
            fi
            first_node=false
            add_node_config
        else
            read -rp "Add another node? (Enter = yes, n/no = exit): " continue_adding_node
            if [[ "$continue_adding_node" =~ ^[Nn][Oo]?$ ]]; then
                break
            elif [ "$fixed_api_info" = false ]; then
                read -rp "Panel URL: " ApiHost
                read -rp "Panel API Key: " ApiKey
            fi
            add_node_config
        fi
    done

    cores_config="["
    if [ "$core_xray" = true ]; then
        cores_config+="
    {
        \"Type\": \"xray\",
        \"Log\": { \"Level\": \"error\", \"ErrorPath\": \"/etc/V2bX/error.log\" },
        \"OutboundConfigPath\": \"/etc/V2bX/custom_outbound.json\",
        \"RouteConfigPath\": \"/etc/V2bX/route.json\"
    },"
    fi
    if [ "$core_sing" = true ]; then
        cores_config+="
    {
        \"Type\": \"sing\",
        \"Log\": { \"Level\": \"error\", \"Timestamp\": true },
        \"NTP\": { \"Enable\": false, \"Server\": \"time.apple.com\", \"ServerPort\": 0 },
        \"OriginalPath\": \"/etc/V2bX/sing_origin.json\"
    },"
    fi
    if [ "$core_hysteria2" = true ]; then
        cores_config+="
    {
        \"Type\": \"hysteria2\",
        \"Log\": { \"Level\": \"error\" }
    },"
    fi
    cores_config+="]"
    cores_config=$(echo "$cores_config" | sed 's/},]$/}]/')

    cd /etc/V2bX
    mv config.json config.json.bak
    nodes_config_str="${nodes_config[*]}"
    formatted_nodes_config="${nodes_config_str%,}"

    cat <<EOF > /etc/V2bX/config.json
{
    "Log": { "Level": "error", "Output": "" },
    "Cores": $cores_config,
    "Nodes": [$formatted_nodes_config]
}
EOF

    cat <<'EOF' > /etc/V2bX/custom_outbound.json
[
    {
        "tag": "IPv4_out",
        "protocol": "freedom",
        "settings": { "domainStrategy": "UseIPv4v6" }
    },
    {
        "tag": "IPv6_out",
        "protocol": "freedom",
        "settings": { "domainStrategy": "UseIPv6" }
    },
    { "protocol": "blackhole", "tag": "block" }
]
EOF

    cat <<'EOF' > /etc/V2bX/route.json
{
    "domainStrategy": "AsIs",
    "rules": [
        { "outboundTag": "block", "ip": [ "geoip:private" ] },
        {
            "outboundTag": "block",
            "domain": [
                "regexp:(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
                "regexp:(.+.|^)(360|so).(cn|com)",
                "regexp:(Subject|HELO|SMTP)",
                "regexp:(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
                "regexp:(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
                "regexp:(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
                "regexp:(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
                "regexp:(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
                "regexp:(.+.|^)(360).(cn|com|net)",
                "regexp:(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
                "regexp:(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
                "regexp:(.*.||)(netvigator|torproject).(com|cn|net|org)",
                "regexp:(..||)(visa|mycard|gash|beanfun|bank).",
                "regexp:(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
                "regexp:(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
                "regexp:(.*.||)(mycard).(com|tw)",
                "regexp:(.*.||)(gash).(com|tw)",
                "regexp:(.bank.)",
                "regexp:(.*.||)(pincong).(rocks)",
                "regexp:(.*.||)(taobao).(com)",
                "regexp:(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
                "regexp:(flows|miaoko).(pages).(dev)"
            ]
        },
        { "outboundTag": "block", "ip": [ "127.0.0.1/32", "10.0.0.0/8", "fc00::/7", "fe80::/10", "172.16.0.0/12" ] },
        { "outboundTag": "block", "protocol": [ "bittorrent" ] },
        { "outboundTag": "IPv4_out", "network": "udp,tcp" }
    ]
}
EOF

    ipv6_support=$(check_ipv6_support)
    dnsstrategy="ipv4_only"
    [[ "$ipv6_support" -eq 1 ]] && dnsstrategy="prefer_ipv4"

    cat <<EOF > /etc/V2bX/sing_origin.json
{
  "dns": {
    "servers": [ { "tag": "cf", "address": "1.1.1.1" } ],
    "strategy": "$dnsstrategy"
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "domain_resolver": { "server": "cf", "strategy": "$dnsstrategy" }
    },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "block" },
      {
        "domain_regex": [
            "(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
            "(.+.|^)(360|so).(cn|com)",
            "(Subject|HELO|SMTP)",
            "(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
            "(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
            "(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
            "(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
            "(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
            "(.+.|^)(360).(cn|com|net)",
            "(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
            "(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
            "(.*.||)(netvigator|torproject).(com|cn|net|org)",
            "(..||)(visa|mycard|gash|beanfun|bank).",
            "(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
            "(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
            "(.*.||)(mycard).(com|tw)",
            "(.*.||)(gash).(com|tw)",
            "(.bank.)",
            "(.*.||)(pincong).(rocks)",
            "(.*.||)(taobao).(com)",
            "(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
            "(flows|miaoko).(pages).(dev)"
        ],
        "outbound": "block"
      },
      { "outbound": "direct", "network": [ "udp", "tcp" ] }
    ]
  },
  "experimental": { "cache_file": { "enabled": true } }
}
EOF

    cat <<'EOF' > /etc/V2bX/hy2config.yaml
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s
resolver:
  type: system
acl:
  inline:
    - direct(geosite:google)
    - reject(geosite:cn)
    - reject(geoip:cn)
masquerade:
  type: 404
EOF

    echo -e "${green}V2bX config generated; restarting service.${plain}"
    restart 0
    before_show_menu
}

open_ports() {
    systemctl stop firewalld.service 2>/dev/null || true
    systemctl disable firewalld.service 2>/dev/null || true
    setenforce 0 2>/dev/null || true
    ufw disable 2>/dev/null || true
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    netfilter-persistent save 2>/dev/null || true
    echo -e "${green}Firewall ports opened.${plain}"
}

show_usage() {
    echo "V2bX management script:"
    echo "------------------------------------------"
    echo "V2bX              - Show menu"
    echo "V2bX start        - Start V2bX"
    echo "V2bX stop         - Stop V2bX"
    echo "V2bX restart      - Restart V2bX"
    echo "V2bX status       - Show status"
    echo "V2bX enable       - Enable at boot"
    echo "V2bX disable      - Disable at boot"
    echo "V2bX log          - View logs"
    echo "V2bX x25519       - Generate x25519 keys"
    echo "V2bX generate     - Generate config file"
    echo "V2bX update       - Update V2bX"
    echo "V2bX update x.x.x - Install specific version"
    echo "V2bX install      - Install V2bX"
    echo "V2bX uninstall    - Uninstall V2bX"
    echo "V2bX version      - Show version"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}V2bX backend manager (not for Docker)${plain}
--- https://github.com/wyx2685/V2bX ---
  ${green}0.${plain} Edit config
----------------------------------------
  ${green}1.${plain} Install V2bX
  ${green}2.${plain} Update V2bX
  ${green}3.${plain} Uninstall V2bX
----------------------------------------
  ${green}4.${plain} Start V2bX
  ${green}5.${plain} Stop V2bX
  ${green}6.${plain} Restart V2bX
  ${green}7.${plain} Status
  ${green}8.${plain} Logs
----------------------------------------
  ${green}9.${plain} Enable at boot
  ${green}10.${plain} Disable at boot
----------------------------------------
  ${green}11.${plain} Install BBR (latest kernel)
  ${green}12.${plain} Show V2bX version
  ${green}13.${plain} Generate x25519 keys
  ${green}14.${plain} Update this helper script
  ${green}15.${plain} Generate V2bX config file
  ${green}16.${plain} Open all firewall ports
  ${green}17.${plain} Exit
 "
    show_status
    echo && read -rp "Choose [0-17]: " num

    case "${num}" in
        0) config ;;
        1) check_uninstall && install ;;
        2) check_install && update ;;
        3) check_install && uninstall ;;
        4) check_install && start ;;
        5) check_install && stop ;;
        6) check_install && restart ;;
        7) check_install && status ;;
        8) check_install && show_log ;;
        9) check_install && enable ;;
        10) check_install && disable ;;
        11) install_bbr ;;
        12) check_install && show_V2bX_version ;;
        13) check_install && generate_x25519_key ;;
        14) update_shell ;;
        15) generate_config_file ;;
        16) open_ports ;;
        17) exit ;;
        *) echo -e "${red}Enter a valid number [0-17].${plain}" ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
        "start") check_install 0 && start 0 ;;
        "stop") check_install 0 && stop 0 ;;
        "restart") check_install 0 && restart 0 ;;
        "status") check_install 0 && status 0 ;;
        "enable") check_install 0 && enable 0 ;;
        "disable") check_install 0 && disable 0 ;;
        "log") check_install 0 && show_log 0 ;;
        "update") check_install 0 && update 0 $2 ;;
        "config") config $* ;;
        "generate") generate_config_file ;;
        "install") check_uninstall 0 && install 0 ;;
        "uninstall") check_install 0 && uninstall 0 ;;
        "x25519") check_install 0 && generate_x25519_key 0 ;;
        "version") check_install 0 && show_V2bX_version 0 ;;
        "update_shell") update_shell ;;
        *) show_usage ;;
    esac
else
    show_menu
fi
