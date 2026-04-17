#!/bin/bash

# ============================================================
#      Xray 协议插件式管理脚本 (骨架版)
# ============================================================

SCRIPT_VERSION="0.3.10"
SCRIPT_CMD_NAME="xtls"
SCRIPT_CMD_ALIAS="XTLS"
SCRIPT_INSTALL_PATH="/usr/local/bin/${SCRIPT_CMD_NAME}"
SCRIPT_ALIAS_PATH="/usr/local/bin/${SCRIPT_CMD_ALIAS}"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/Ezrea7/xTLS-Reality/refs/heads/main/xray.sh"
SELF_SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_PID_FILE="/tmp/xray.pid"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_DIR="/usr/local/etc/sing-box"
SINGBOX_CONFIG="${SINGBOX_DIR}/config.json"
SINGBOX_PID_FILE="/tmp/sing-box.pid"
META_DIR="/usr/local/etc/xtls"
META_FILE="${META_DIR}/metadata.json"
DEFAULT_SNI="support.apple.com"
IP_PREF_FILE="${XRAY_DIR}/ip_preference.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()    { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
_warn()    { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
_error()   { echo -e "${RED}[错误] $1${NC}" >&2; }

trap 'rm -f "${XRAY_DIR}"/*.tmp.* "${SINGBOX_DIR}"/*.tmp.* "${META_DIR}"/*.tmp.* 2>/dev/null || true' EXIT

# ===================== 基础与通用 =====================

_pause() {
    [ -t 0 ] || return 0
    echo ""
    read -p "按回车键继续..." _
}

_menu_item()   { printf "  ${GREEN}[%-2s]${NC} %s\n" "$1" "$2"; }
_menu_danger() { printf "  ${RED}[%-2s]${NC} %s\n" "$1" "$2"; }
_menu_exit()   { printf "  ${YELLOW}[%-2s]${NC} %s\n" "$1" "$2"; }
_confirm_yes() {
    local answer="$1"
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

_check_root() {
    if [ "$EUID" -ne 0 ]; then
        _error "请使用 root 权限运行。"
        exit 1
    fi
}

_detect_init_system() {
    if [ -f /sbin/openrc-run ] || command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="unknown"
    fi
}

_download_to() {
    local url="$1" output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -LfsS "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$output"
    else
        return 1
    fi
}

_pkg_install() {
    local pkgs="$*"
    [ -z "$pkgs" ] && return 0
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache $pkgs >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls -A /var/lib/apt/lists/ 2>/dev/null | wc -l)" -le 1 ]; then
            apt-get update -qq >/dev/null 2>&1
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null 2>&1 || {
            apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null 2>&1
        }
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $pkgs >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $pkgs >/dev/null 2>&1
    fi
}

_ensure_deps() {
    local missing="" still_missing="" c

    for c in bash jq openssl awk sed grep unzip; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing="$missing curl"
    command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || _pkg_install iproute2 net-tools
    if command -v apk >/dev/null 2>&1; then
        [ -f /etc/ssl/certs/ca-certificates.crt ] || missing="$missing ca-certificates"
    fi
    [ -n "$missing" ] && _pkg_install $missing

    for c in bash jq openssl awk sed grep unzip; do
        command -v "$c" >/dev/null 2>&1 || still_missing="$still_missing $c"
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || still_missing="$still_missing curl"
    command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || still_missing="$still_missing iproute2/net-tools"

    if [ -n "$still_missing" ]; then
        _error "缺少依赖: ${still_missing# }"
        return 1
    fi
}

_install_script_shortcut() {
    local src
    src="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    [ -n "$src" ] && [ -f "$src" ] || return 0

    mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")" 2>/dev/null || true
    [ "$src" != "$SCRIPT_INSTALL_PATH" ] && cp -f "$src" "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
    ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH" 2>/dev/null || cp -f "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_ALIAS_PATH" 2>/dev/null || true
}

_update_script_self() {
    local tmp="/tmp/${SCRIPT_CMD_NAME}.update.$$"
    local src
    src="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

    _download_to "$SCRIPT_UPDATE_URL" "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        _error "下载更新失败。"
        return 1
    }

    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        _error "更新文件语法校验失败，已取消覆盖。"
        return 1
    fi

    mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")" 2>/dev/null || true
    cp -f "$tmp" "$SCRIPT_INSTALL_PATH" || {
        rm -f "$tmp"
        _error "写入 ${SCRIPT_INSTALL_PATH} 失败。"
        return 1
    }
    chmod +x "$SCRIPT_INSTALL_PATH" 2>/dev/null || true

    if [ -n "$src" ] && [ -f "$src" ] && [ "$src" != "$SCRIPT_INSTALL_PATH" ]; then
        cp -f "$tmp" "$src" 2>/dev/null || true
        chmod +x "$src" 2>/dev/null || true
    fi

    rm -f "$tmp"
    ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH" 2>/dev/null || cp -f "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_ALIAS_PATH" 2>/dev/null || true

    _success "脚本更新完成。当前快捷命令: ${SCRIPT_CMD_NAME} / ${SCRIPT_CMD_ALIAS}"
    _warn "请重新运行 ${SCRIPT_CMD_NAME} 或 ${SCRIPT_CMD_ALIAS} 以加载新版本。"
}

# ===================== 网络与环境 =====================

_get_ip_preference() {
    local pref=""
    if [ -f "$IP_PREF_FILE" ]; then
        pref=$(tr -d '\n\r' < "$IP_PREF_FILE" 2>/dev/null | tr 'A-Z' 'a-z')
    fi
    case "$pref" in
        ipv4|ipv6) echo "$pref" ;;
        *) echo "ipv4" ;;
    esac
}

_apply_system_ip_preference() {
    local pref="$1"
    local gai_conf="/etc/gai.conf"
    [ -f "$gai_conf" ] || touch "$gai_conf"
    sed -i -e "/^[[:space:]]*precedence[[:space:]]\+::ffff:0:0\/96/ s/^/#/" "$gai_conf"
    if [ "$pref" = "ipv4" ] && ! grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' "$gai_conf"; then
        echo 'precedence ::ffff:0:0/96 100' >> "$gai_conf"
    fi
}

_set_ip_preference() {
    local pref="$1"
    case "$pref" in
        ipv4|ipv6)
            mkdir -p "$XRAY_DIR" 2>/dev/null || true
            echo "$pref" > "$IP_PREF_FILE" 2>/dev/null || return 1
            _apply_system_ip_preference "$pref"
            unset server_ip
            ;;
        *) return 1 ;;
    esac
}

_fetch_ip_by_proto() {
    local proto="$1" ip=""

    if command -v curl >/dev/null 2>&1; then
        if [ "$proto" = "ipv6" ]; then
            ip=$(curl -s6 --max-time 5 icanhazip.com 2>/dev/null || curl -s6 --max-time 5 ipinfo.io/ip 2>/dev/null || curl -s6 --max-time 5 api6.ipify.org 2>/dev/null || true)
        else
            ip=$(curl -s4 --max-time 5 icanhazip.com 2>/dev/null || curl -s4 --max-time 5 ipinfo.io/ip 2>/dev/null || curl -s4 --max-time 5 api.ipify.org 2>/dev/null || true)
        fi
    fi

    if [ -z "$ip" ] && command -v wget >/dev/null 2>&1; then
        if [ "$proto" = "ipv6" ]; then
            ip=$(wget -qO- -6 --timeout=5 icanhazip.com 2>/dev/null || wget -qO- -6 --timeout=5 ipinfo.io/ip 2>/dev/null || wget -qO- -6 --timeout=5 api6.ipify.org 2>/dev/null || true)
        else
            ip=$(wget -qO- -4 --timeout=5 icanhazip.com 2>/dev/null || wget -qO- -4 --timeout=5 ipinfo.io/ip 2>/dev/null || wget -qO- -4 --timeout=5 api.ipify.org 2>/dev/null || true)
        fi
    fi

    printf '%s' "$ip"
}

_get_public_ip() {
    [ -n "$server_ip" ] && { echo "$server_ip"; return; }

    local pref ip=""
    pref=$(_get_ip_preference)

    if [ "$pref" = "ipv6" ]; then
        ip=$(_fetch_ip_by_proto ipv6)
        [ -z "$ip" ] && ip=$(_fetch_ip_by_proto ipv4)
    else
        ip=$(_fetch_ip_by_proto ipv4)
        [ -z "$ip" ] && ip=$(_fetch_ip_by_proto ipv6)
    fi

    server_ip="$ip"
    echo "$ip"
}

_choose_ip_preference() {
    local current ip4 ip6 display_pref choice
    current=$(_get_ip_preference)
    ip4=$(_fetch_ip_by_proto ipv4)
    ip6=$(_fetch_ip_by_proto ipv6)
    [ "$current" = "ipv6" ] && display_pref="IPv6" || display_pref="IPv4"

    echo ""
    echo -e "${CYAN}当前网络优先级设置: ${NC}${GREEN}${display_pref} 优先${NC}"
    echo ""
    echo -e "检测到 IPv4 地址: ${YELLOW}${ip4:-无}${NC}"
    echo -e "检测到 IPv6 地址: ${YELLOW}${ip6:-无}${NC}"
    echo ""
    echo "请选择网络优先级:"
    echo -e "  ${GREEN}[1]${NC} IPv4 优先"
    echo -e "  ${GREEN}[2]${NC} IPv6 优先"
    echo -e "  ${YELLOW}[0]${NC} 返回上一级"
    read -p "请选择 [0-2]: " choice

    case "$choice" in
        1)
            [ -n "$ip4" ] || { _error "当前未检测到可用的 IPv4 地址，无法设置 IPv4 优先。"; _pause; return 0; }
            _set_ip_preference ipv4 && _success "IPv4 优先设置完成。" || _error "设置 IPv4 优先失败。"
            ;;
        2)
            [ -n "$ip6" ] || { _error "当前未检测到可用的 IPv6 地址，无法设置 IPv6 优先。"; _pause; return 0; }
            _set_ip_preference ipv6 && _success "IPv6 优先设置完成。" || _error "设置 IPv6 优先失败。"
            ;;
        0) return 0 ;;
        *) _error "无效输入。" ;;
    esac
    _pause
}

_init_server_ip() {
    server_ip=$(_get_public_ip)
    if [ -z "$server_ip" ] || [ "$server_ip" = "null" ]; then
        _warn "自动获取 IP 失败，请添加节点时手动输入。"
        server_ip=""
    fi
}

_get_os_pretty_name() {
    local os_name os_ver
    if [ -r /etc/os-release ]; then
        os_name=$(awk -F= '/^NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
        os_ver=$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
        [ -n "$os_name" ] && {
            [ -n "$os_ver" ] && printf '%s v%s\n' "$os_name" "$os_ver" || printf '%s\n' "$os_name"
            return 0
        }
    fi
    uname -s
}

_get_singbox_core_version() {
    [ -x "$SINGBOX_BIN" ] || { echo "未安装"; return 0; }
    local version
    version=$($SINGBOX_BIN version 2>/dev/null | head -n1 | awk '{print $3}')
    [ -n "$version" ] && echo "v${version}" || echo "未知版本"
}

_get_singbox_service_status() {
    [ -x "$SINGBOX_BIN" ] || { echo "未安装"; return 0; }

    local active=""
    case "$INIT_SYSTEM" in
        systemd)
            systemctl is-active --quiet sing-box >/dev/null 2>&1 && active=1 || active=0
            ;;
        openrc)
            rc-service sing-box status >/dev/null 2>&1 && active=1 || active=0
            ;;
        *)
            pgrep -f "$SINGBOX_BIN" >/dev/null 2>&1 && active=1 || active=0
            ;;
    esac

    if [ "$active" = "1" ]; then
        echo "● 运行中"
    else
        echo "○ 未运行"
    fi
}

_get_singbox_node_count() {
    [ -f "$SINGBOX_CONFIG" ] || { echo "0"; return 0; }
    jq -r '.inbounds | length' "$SINGBOX_CONFIG" 2>/dev/null || echo "0"
}

# ===================== Xray 核心与服务 =====================

_atomic_modify_json() {
    local file="$1" filter="$2"
    [ -f "$file" ] || { _error "文件不存在: $file"; return 1; }
    local tmp="${file}.tmp.$$"
    if jq "$filter" "$file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        _error "JSON 修改失败: $file"
        return 1
    fi
}

_check_port_occupied() {
    local port="$1" proto="${2:-tcp}"
    if command -v ss >/dev/null 2>&1; then
        if ss -lntup 2>/dev/null | awk -v p=":${port}" '$0 ~ p {found=1} END{exit !found}'; then
            return 0
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -lntup 2>/dev/null | awk -v p=":${port}" '$0 ~ p {found=1} END{exit !found}'; then
            return 0
        fi
    fi
    return 1
}

_check_port_in_configs() {
    local port="$1"
    if [ -f "$XRAY_CONFIG" ] && jq -e --argjson p "$port" '.inbounds[] | select(.port == $p)' "$XRAY_CONFIG" >/dev/null 2>&1; then
        return 0
    fi
    if [ -f "$SINGBOX_CONFIG" ] && jq -e --argjson p "$port" '.inbounds[] | select(.listen_port == $p)' "$SINGBOX_CONFIG" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

_check_port_conflict() {
    local port="$1" proto="${2:-tcp}"
    if _check_port_in_configs "$port"; then
        _error "端口 ${port} 已存在于当前节点配置中，请更换端口。"
        return 0
    fi
    if _check_port_occupied "$port" "$proto"; then
        _error "端口 ${port} 已被系统进程占用，请更换端口。"
        return 0
    fi
    return 1
}

_input_port() {
    local port=""
    while true; do
        read -p "请输入监听端口: " port
        [[ -z "$port" ]] && _error "端口不能为空。" && continue
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            _error "无效端口号。"
            continue
        fi
        _check_port_conflict "$port" && continue
        echo "$port"
        return 0
    done
}

_input_uuid() {
    local uuid=""
    while true; do
        read -p "请输入 UUID (回车自动生成): " uuid
        if [ -z "$uuid" ]; then
            if command -v uuidgen >/dev/null 2>&1; then
                uuid=$(uuidgen | tr 'A-Z' 'a-z')
            elif [ -f /proc/sys/kernel/random/uuid ]; then
                uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr 'A-Z' 'a-z')
            else
                uuid=$(openssl rand -hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/')
            fi
            printf '%s\n' "$uuid"
            return 0
        fi
        if printf '%s' "$uuid" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
            printf '%s\n' "$(printf '%s' "$uuid" | tr 'A-Z' 'a-z')"
            return 0
        fi
        _error "UUID 格式无效，请重新输入。"
    done
}

_input_node_ip() {
    local node_ip custom_ip
    [ -z "$server_ip" ] && _init_server_ip
    node_ip="$server_ip"

    if [ -n "$server_ip" ]; then
        read -p "请输入服务器 IP (回车默认当前检测 IP: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
    else
        _warn "未能自动检测到当前公网 IP，请手动输入。"
        read -p "请输入服务器 IP: " node_ip
    fi
    printf '%s\n' "$node_ip"
}

_input_sni() {
    local default_sni="$1" custom_sni
    [ -n "$default_sni" ] || default_sni="$DEFAULT_SNI"
    read -p "请输入伪装域名 SNI (默认: ${default_sni}): " custom_sni
    printf '%s\n' "${custom_sni:-$default_sni}"
}

_input_node_name() {
    local protocol="$1" port="$2" default_name custom_name name tag
    default_name=$(_protocol_default_name "$protocol" "$port")
    while true; do
        read -p "请输入节点名称 (默认: ${default_name}): " custom_name
        name=${custom_name:-$default_name}
        tag="$name"
        if _list_tags | grep -Fxq "$tag"; then
            _error "节点名称已存在，请重新输入。"
            continue
        fi
        printf '%s\n' "$name"
        return 0
    done
}

_init_xray_config() {
    mkdir -p "$XRAY_DIR"

    if [ ! -s "$XRAY_CONFIG" ]; then
        cat > "$XRAY_CONFIG" <<'JSON'
{
  "log": {
    "access": "none",
    "error": "none",
    "loglevel": "none"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
JSON
        _success "Xray 配置文件初始化完成。"
    fi

    mkdir -p "$META_DIR"
    [ -s "$META_FILE" ] || echo '{}' > "$META_FILE"
}

_create_xray_systemd_service() {
    cat > /etc/systemd/system/xray.service <<EOF2
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF2
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable xray >/dev/null 2>&1 || true
}

_create_xray_openrc_service() {
    cat > /etc/init.d/xray <<EOF2
#!/sbin/openrc-run
description="Xray Service"
command="${XRAY_BIN}"
command_args="run -c ${XRAY_CONFIG}"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
pidfile="${XRAY_PID_FILE}"
output_log="/dev/null"
error_log="/dev/null"

depend() {
    need net
    after firewall
}
EOF2
    chmod +x /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
}

_create_xray_service() {
    case "$INIT_SYSTEM" in
        systemd) _create_xray_systemd_service ;;
        openrc) _create_xray_openrc_service ;;
        *) _warn "未检测到 systemd/openrc，请手动管理 Xray 进程。" ;;
    esac
}

_get_xray_core_version() {
    [ -x "$XRAY_BIN" ] || { echo "未安装"; return 0; }
    local version
    version=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
    [ -n "$version" ] && echo "v${version}" || echo "未知版本"
}

_get_xray_node_count() {
    [ -f "$XRAY_CONFIG" ] || { echo "0"; return 0; }
    jq -r '.inbounds | length' "$XRAY_CONFIG" 2>/dev/null || echo "0"
}

_get_xray_service_status() {
    [ -x "$XRAY_BIN" ] || { echo "未安装"; return 0; }

    local active=""
    case "$INIT_SYSTEM" in
        systemd)
            systemctl is-active --quiet xray >/dev/null 2>&1 && active=1 || active=0
            ;;
        openrc)
            rc-service xray status >/dev/null 2>&1 && active=1 || active=0
            ;;
        *)
            pgrep -f "$XRAY_BIN" >/dev/null 2>&1 && active=1 || active=0
            ;;
    esac

    if [ "$active" = "1" ]; then
        echo "● 运行中"
    else
        echo "○ 未运行"
    fi
}

_show_xray_runtime_summary() {
    local os_info singbox_status
    os_info=$(_get_os_pretty_name)
    singbox_status="$(_get_singbox_service_status) ($(_get_singbox_node_count)节点)"
    echo -e " 系统: ${CYAN}${os_info}${NC}  |  模式: ${CYAN}${INIT_SYSTEM}${NC}"
    echo -e " Xray ${YELLOW}$(_get_xray_core_version)${NC}: ${GREEN}$(_get_xray_service_status)${NC} ($(_get_xray_node_count)节点)"
    echo -e " Sing-box ${YELLOW}$(_get_singbox_core_version)${NC}: ${GREEN}${singbox_status}${NC}"
    echo -e "--------------------------------------------------"
}

_require_xray() {
    [ -x "$XRAY_BIN" ] && return 0
    _warn "当前未安装 Xray 内核。"
    _warn "请先执行 [1] 安装/更新 Xray 内核。"
    return 1
}

_require_singbox() {
    [ -x "$SINGBOX_BIN" ] && return 0
    _warn "当前未安装 Sing-box 内核。"
    _warn "请先执行 [2] 安装/更新 Sing-box 核心。"
    return 1
}

_manage_xray_service() {
    local action="$1" result=1

    [ -x "$XRAY_BIN" ] || { _error "Xray 内核未安装。"; return 1; }
    [ -z "$INIT_SYSTEM" ] && _detect_init_system

    [ "$action" = "status" ] || _info "正在使用 ${INIT_SYSTEM} 执行: ${action}..."

    case "$INIT_SYSTEM" in
        systemd)
            if [ "$action" = "status" ]; then
                systemctl status xray --no-pager -l
                return
            fi
            systemctl "$action" xray >/dev/null 2>&1
            result=$?
            ;;
        openrc)
            if [ "$action" = "status" ]; then
                rc-service xray status
                return
            fi
            rc-service xray "$action" >/dev/null 2>&1
            result=$?
            ;;
        *)
            _warn "未检测到服务管理器，跳过 ${action}。"
            return 0
            ;;
    esac

    [ "$result" -eq 0 ] || { _error "Xray 服务${action}失败。"; return 1; }

    case "$action" in
        start) _success "Xray 服务启动成功。" ;;
        stop) _success "Xray 服务停止成功。" ;;
        restart) _success "Xray 服务重启成功。" ;;
    esac
}

_create_singbox_systemd_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF2
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONFIG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535
NoNewPrivileges=true
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF2
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable sing-box >/dev/null 2>&1 || true
}

_create_singbox_openrc_service() {
    cat > /etc/init.d/sing-box <<EOF2
#!/sbin/openrc-run
description="Sing-box Service"
command="${SINGBOX_BIN}"
command_args="run -c ${SINGBOX_CONFIG}"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
pidfile="${SINGBOX_PID_FILE}"
output_log="/dev/null"
error_log="/dev/null"

depend() {
    need net
    after firewall
}
EOF2
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1 || true
}

_create_singbox_service() {
    case "$INIT_SYSTEM" in
        systemd) _create_singbox_systemd_service ;;
        openrc) _create_singbox_openrc_service ;;
        *) _warn "未检测到 systemd/openrc，请手动管理 Sing-box 进程。" ;;
    esac
}

_manage_singbox_service() {
    local action="$1" result=1

    [ -x "$SINGBOX_BIN" ] || { _error "Sing-box 内核未安装。"; return 1; }
    [ -z "$INIT_SYSTEM" ] && _detect_init_system

    [ "$action" = "status" ] || _info "正在使用 ${INIT_SYSTEM} 执行: ${action}..."

    case "$INIT_SYSTEM" in
        systemd)
            if [ "$action" = "status" ]; then
                systemctl status sing-box --no-pager -l
                return
            fi
            systemctl "$action" sing-box >/dev/null 2>&1
            result=$?
            ;;
        openrc)
            if [ "$action" = "status" ]; then
                rc-service sing-box status
                return
            fi
            rc-service sing-box "$action" >/dev/null 2>&1
            result=$?
            ;;
        *)
            _warn "未检测到服务管理器，跳过 ${action}。"
            return 0
            ;;
    esac

    [ "$result" -eq 0 ] || { _error "Sing-box 服务${action}失败。"; return 1; }

    case "$action" in
        start) _success "Sing-box 服务启动成功。" ;;
        stop) _success "Sing-box 服务停止成功。" ;;
        restart) _success "Sing-box 服务重启成功。" ;;
    esac
}

_init_singbox_config() {
    mkdir -p "$SINGBOX_DIR"
    if [ ! -s "$SINGBOX_CONFIG" ]; then
        cat > "$SINGBOX_CONFIG" <<'JSON'
{
  "log": {
    "disabled": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
JSON
        _success "Sing-box 配置文件初始化完成。"
    fi
}

_install_or_update_singbox() {
    if [ -f "${SINGBOX_BIN}" ]; then
        local current_ver=$(${SINGBOX_BIN} version 2>/dev/null | head -n1 | awk '{print $3}')
        _info "当前 Sing-box 版本: v${current_ver}，正在检查更新..."
    else
        _info "Sing-box 核心未安装，正在执行首次安装..."
    fi

    _info "--- 安装/更新 Sing-box 核心 ---"
    local arch arch_tag libc_suffix api_url search_pattern release_info download_url checksum_url checksums dl_filename expected_hash actual_hash temp_dir
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='armv7' ;;
        *) _error "不支持的架构：$arch"; return 1 ;;
    esac

    libc_suffix=""
    if ldd --version 2>&1 | grep -qi musl || [ -f /etc/alpine-release ]; then
        libc_suffix="-musl"
    fi

    api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    search_pattern="linux-${arch_tag}${libc_suffix}.tar.gz"
    release_info=$(curl -s "$api_url")
    download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name | contains(\"${search_pattern}\")) | .browser_download_url" | head -1)
    checksum_url=$(echo "$release_info" | jq -r '.assets[] | select(.name | endswith("checksums.txt")) | .browser_download_url' | head -1)

    [ -n "$download_url" ] || { _error "无法获取 sing-box 下载链接。"; return 1; }
    _download_to "$download_url" /tmp/sing-box.tar.gz || { _error "sing-box 下载失败。"; return 1; }

    if [ -n "$checksum_url" ]; then
        checksums=$(_download_to "$checksum_url" /tmp/sing-box.checksums >/dev/null 2>&1 && cat /tmp/sing-box.checksums 2>/dev/null)
        if [ -n "$checksums" ]; then
            dl_filename=$(basename "$download_url")
            expected_hash=$(echo "$checksums" | grep "$dl_filename" | awk '{print $1}')
            if [ -n "$expected_hash" ]; then
                actual_hash=$(sha256sum /tmp/sing-box.tar.gz | awk '{print $1}')
                [ "$expected_hash" = "$actual_hash" ] || { _error "sing-box SHA256 校验失败。"; rm -f /tmp/sing-box.tar.gz /tmp/sing-box.checksums; return 1; }
            fi
        fi
    fi

    temp_dir=$(mktemp -d)
    tar -xzf /tmp/sing-box.tar.gz -C "$temp_dir" || { rm -rf "$temp_dir" /tmp/sing-box.tar.gz /tmp/sing-box.checksums; _error "sing-box 解压失败。"; return 1; }
    mv "$temp_dir"/sing-box-*/sing-box "$SINGBOX_BIN" || { rm -rf "$temp_dir" /tmp/sing-box.tar.gz /tmp/sing-box.checksums; _error "未找到 sing-box 二进制。"; return 1; }
    chmod +x "$SINGBOX_BIN"
    rm -rf "$temp_dir" /tmp/sing-box.tar.gz /tmp/sing-box.checksums

    _init_singbox_config
    _create_singbox_service
    _manage_singbox_service restart >/dev/null 2>&1 || _manage_singbox_service start >/dev/null 2>&1 || true
    _success "Sing-box 核心安装/更新完成。当前版本: $($SINGBOX_BIN version 2>/dev/null | head -n1)"
}

_install_or_update_xray() {
    local is_first_install=false current_ver arch xray_arch download_url tmp_dir tmp_zip version
    [ ! -f "$XRAY_BIN" ] && is_first_install=true

    if [ "$is_first_install" = true ]; then
        _info "Xray 核心未安装，正在执行首次安装..."
    else
        current_ver=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
        _info "当前 Xray 版本: v${current_ver}，正在检查更新..."
    fi

    command -v unzip >/dev/null 2>&1 || _pkg_install unzip

    arch=$(uname -m)
    xray_arch="64"
    case "$arch" in
        x86_64|amd64) xray_arch="64" ;;
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        armv7l) xray_arch="arm32-v7a" ;;
    esac

    download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip"
    tmp_dir=$(mktemp -d)
    tmp_zip="${tmp_dir}/xray.zip"

    _info "下载地址: ${download_url}"
    _download_to "$download_url" "$tmp_zip" || {
        _error "Xray 下载失败。"
        rm -rf "$tmp_dir"
        return 1
    }

    unzip -qo "$tmp_zip" -d "$tmp_dir" || {
        _error "Xray 解压失败。"
        rm -rf "$tmp_dir"
        return 1
    }
    [ -f "${tmp_dir}/xray" ] || { _error "压缩包中未找到 xray 二进制。"; rm -rf "$tmp_dir"; return 1; }

    mv "${tmp_dir}/xray" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    mkdir -p "$XRAY_DIR"
    [ -f "${tmp_dir}/geoip.dat" ] && mv "${tmp_dir}/geoip.dat" "$XRAY_DIR/"
    [ -f "${tmp_dir}/geosite.dat" ] && mv "${tmp_dir}/geosite.dat" "$XRAY_DIR/"
    rm -rf "$tmp_dir"

    version=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
    _success "Xray 内核安装/更新完成，当前版本: v${version}。"

    _init_xray_config
    _create_xray_service

    if [ "$is_first_install" = true ]; then
        _info "首次安装 Xray，正在初始化配置与服务..."
        _set_ip_preference ipv4 >/dev/null 2>&1 || true
        _manage_xray_service start
        _success "Xray 首次安装已完成，服务已启动。"
    else
        _manage_xray_service restart
    fi
}

_cleanup_xray_files() {
    _manage_xray_service stop >/dev/null 2>&1 || true

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl disable xray >/dev/null 2>&1
        rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-update del xray default >/dev/null 2>&1
        rm -f /etc/init.d/xray
    fi

    rm -f "$XRAY_BIN" "$XRAY_PID_FILE"
    rm -rf "$XRAY_DIR"
    if [ ! -d "$SINGBOX_DIR" ] || [ -z "$(find "$SINGBOX_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        rm -f "$META_FILE"
        rmdir "$META_DIR" 2>/dev/null || true
    fi
}

_cleanup_singbox_files() {
    _manage_singbox_service stop >/dev/null 2>&1 || true

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl disable sing-box >/dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-update del sing-box default >/dev/null 2>&1
        rm -f /etc/init.d/sing-box
    fi

    rm -f "$SINGBOX_BIN" "$SINGBOX_PID_FILE"
    rm -rf "$SINGBOX_DIR"
    if [ ! -d "$XRAY_DIR" ] || [ -z "$(find "$XRAY_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        rm -f "$META_FILE"
        rmdir "$META_DIR" 2>/dev/null || true
    fi
}

_uninstall_xray() {
    echo ""
    _warn "即将卸载 Xray 内核及相关配置。"
    printf "${YELLOW}确定要继续吗? (y/N): ${NC}"
    read -r confirm
    _confirm_yes "$confirm" || { _info "卸载已取消。"; return; }

    _cleanup_xray_files
    _success "Xray 内核卸载完成。"
}

_uninstall_singbox() {
    echo ""
    _warn "即将卸载 Sing-box 内核及相关配置。"
    printf "${YELLOW}确定要继续吗? (y/N): ${NC}"
    read -r confirm
    _confirm_yes "$confirm" || { _info "卸载已取消。"; return; }

    _cleanup_singbox_files
    _success "Sing-box 内核卸载完成。"
}

_uninstall_script() {
    _warn "！！！警告！！！"
    _warn "本操作将停止并禁用 Xray / Sing-box 服务，"
    _warn "删除所有相关文件（包括二进制、配置文件、快捷命令及脚本本体）。"

    echo ""
    echo "即将删除以下内容："
    echo -e "  ${RED}-${NC} Xray 配置目录: ${XRAY_DIR}"
    echo -e "  ${RED}-${NC} Xray 二进制: ${XRAY_BIN}"
    echo -e "  ${RED}-${NC} Sing-box 配置目录: ${SINGBOX_DIR}"
    echo -e "  ${RED}-${NC} Sing-box 二进制: ${SINGBOX_BIN}"
    echo -e "  ${RED}-${NC} 系统快捷命令: ${SCRIPT_INSTALL_PATH}"
    [ "$SCRIPT_ALIAS_PATH" != "$SCRIPT_INSTALL_PATH" ] && echo -e "  ${RED}-${NC} 系统快捷命令: ${SCRIPT_ALIAS_PATH}"
    [ -n "$SELF_SCRIPT_PATH" ] && [ -f "$SELF_SCRIPT_PATH" ] && echo -e "  ${RED}-${NC} 管理脚本: ${SELF_SCRIPT_PATH}"
    echo ""

    printf "${YELLOW}确定要执行卸载吗? (y/N): ${NC}"
    read -r confirm_main
    _confirm_yes "$confirm_main" || { _info "卸载已取消。"; return; }

    _cleanup_xray_files
    _cleanup_singbox_files

    _info "正在清理快捷命令与脚本本体..."
    rm -f "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH"
    if [ -n "$SELF_SCRIPT_PATH" ] && [ -f "$SELF_SCRIPT_PATH" ] && [ "$SELF_SCRIPT_PATH" != "$SCRIPT_INSTALL_PATH" ]; then
        rm -f "$SELF_SCRIPT_PATH"
    fi

    _success "清理完成。脚本已自毁。再见！"
    [ -n "$SELF_SCRIPT_PATH" ] && [ -f "$SELF_SCRIPT_PATH" ] && rm -f "$SELF_SCRIPT_PATH"
    exit 0
}

# ===================== 协议公共能力 =====================

_generate_reality_keys() {
    local keypair
    keypair=$($XRAY_BIN x25519 2>&1)
    REALITY_PRIVATE_KEY=$(echo "$keypair" | awk 'NR==1 {print $NF}')
    REALITY_PUBLIC_KEY=$(echo "$keypair" | awk 'NR==2 {print $NF}')
    REALITY_SHORT_ID=$(openssl rand -hex 8)

    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
        _error "Reality 密钥生成失败。"
        echo "$keypair" >&2
        return 1
    fi
}

_build_reality_stream() {
    local network="$1" sni="$2" private_key="$3" short_id="$4"
    jq -n --arg net "$network" --arg sni "$sni" --arg pk "$private_key" --arg sid "$short_id" '
        {
            "network": $net,
            "security": "reality",
            "realitySettings": {
                "show": false,
                "target": ($sni + ":443"),
                "xver": 0,
                "serverNames": [$sni],
                "privateKey": $pk,
                "shortIds": [$sid]
            }
        }'
}

_get_inbound_field() {
    local tag="$1" field="$2" protocol
    protocol=$(_get_meta_field "$tag" protocol)
    if [ "$protocol" = "anytls_reality" ]; then
        jq --arg tag "$tag" -r ".inbounds[] | select(.tag == \$tag) | ${field} // empty" "$SINGBOX_CONFIG" 2>/dev/null
    else
        jq --arg tag "$tag" -r ".inbounds[] | select(.tag == \$tag) | ${field} // empty" "$XRAY_CONFIG" 2>/dev/null
    fi
}

_get_meta_field() {
    local tag="$1" field="$2"
    jq --arg tag "$tag" --arg field "$field" -r '.[$tag][$field] // empty' "$META_FILE" 2>/dev/null
}

_set_meta_field() {
    local tag="$1" key="$2" value="$3"
    _atomic_modify_json "$META_FILE" ".\"$tag\".\"$key\" = \"$value\"" >/dev/null 2>&1
}

_save_meta_bundle() {
    local tag="$1" name="$2" link="$3"
    shift 3

    mkdir -p "$META_DIR"
    [ -s "$META_FILE" ] || echo '{}' > "$META_FILE"
    _atomic_modify_json "$META_FILE" ". + {\"$tag\": {name: \"$name\", qx_link: \"$link\"}}" || return 1

    for pair in "$@"; do
        local key="${pair%%=*}" val="${pair#*=}"
        [ -n "$key" ] && [ -n "$val" ] || continue
        _set_meta_field "$tag" "$key" "$val" || true
    done
}

_get_tag_name() {
    local tag="$1" name
    name=$(_get_meta_field "$tag" name)
    [ -n "$name" ] && printf '%s\n' "$name" || printf '%s\n' "$tag"
}

_get_inbound_port() {
    local tag="$1" protocol
    protocol=$(_get_meta_field "$tag" protocol)
    if [ "$protocol" = "anytls_reality" ]; then
        jq --arg tag "$tag" -r '.inbounds[] | select(.tag == $tag) | .listen_port // empty' "$SINGBOX_CONFIG" 2>/dev/null
    else
        jq --arg tag "$tag" -r '.inbounds[] | select(.tag == $tag) | .port // empty' "$XRAY_CONFIG" 2>/dev/null
    fi
}

_get_inbound_display_protocol() {
    local tag="$1" protocol
    protocol=$(_get_meta_field "$tag" protocol)
    case "$protocol" in
        anytls_reality) echo "anytls+reality+raw" ;;
        *)
            local proto network security
            proto=$(_get_inbound_field "$tag" '.protocol')
            network=$(_get_inbound_field "$tag" '.streamSettings.network // "raw"')
            security=$(_get_inbound_field "$tag" '.streamSettings.security // "none"')
            echo "${proto}+${security}+${network}"
            ;;
    esac
}

_list_tags() {
    {
        jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null
        jq -r '.inbounds[].tag' "$SINGBOX_CONFIG" 2>/dev/null
    } | awk 'NF && !seen[$0]++'
}

_has_nodes() {
    {
        [ -f "$XRAY_CONFIG" ] && jq -e '.inbounds | length > 0' "$XRAY_CONFIG" >/dev/null 2>&1 && echo 1
        [ -f "$SINGBOX_CONFIG" ] && jq -e '.inbounds | length > 0' "$SINGBOX_CONFIG" >/dev/null 2>&1 && echo 1
    } | grep -q 1
}

_select_tag() {
    local prompt="$1" choice i=1
    local -a tags
    mapfile -t tags < <(_list_tags)
    [ "${#tags[@]}" -gt 0 ] || return 1

    echo "" >&2
    echo -e "${YELLOW}${prompt}${NC}" >&2
    for tag in "${tags[@]}"; do
        echo -e "  ${GREEN}[${i}]${NC} $(_get_tag_name "$tag") (端口: $(_get_inbound_port "$tag"))" >&2
        i=$((i + 1))
    done
    echo -e "  ${RED}[0]${NC} 返回" >&2
    echo "" >&2
    read -p "请选择 [0-${#tags[@]}]: " choice >&2

    [ "$choice" = "0" ] && return 1
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tags[@]}" ]; then
        _error "无效选择。"
        return 1
    fi
    printf '%s\n' "${tags[$((choice-1))]}"
}

_delete_inbound_by_tag() {
    local tag="$1" protocol
    protocol=$(_get_meta_field "$tag" protocol)
    if [ "$protocol" = "anytls_reality" ]; then
        _atomic_modify_json "$SINGBOX_CONFIG" "del(.inbounds[] | select(.tag == \"$tag\"))" || {
            _error "删除节点配置失败。"
            return 1
        }
    else
        _atomic_modify_json "$XRAY_CONFIG" "del(.inbounds[] | select(.tag == \"$tag\"))" || {
            _error "删除节点配置失败。"
            return 1
        }
    fi
}

_update_inbound_port_and_tag() {
    local tag="$1" new_port="$2" new_tag="$3" protocol
    protocol=$(_get_meta_field "$tag" protocol)
    if [ "$protocol" = "anytls_reality" ]; then
        _atomic_modify_json "$SINGBOX_CONFIG" "(.inbounds[] | select(.tag == \"$tag\") | .listen_port) = $new_port | (.inbounds[] | select(.tag == \"$tag\") | .tag) = \"$new_tag\" | (.inbounds[] | select(.tag == \"$new_tag\") | .users[0].name) = \"$new_tag\"" || {
            _error "更新节点端口失败。"
            return 1
        }
    else
        _atomic_modify_json "$XRAY_CONFIG" "(.inbounds[] | select(.tag == \"$tag\") | .port) = $new_port | (.inbounds[] | select(.tag == \"$tag\") | .tag) = \"$new_tag\"" || {
            _error "更新节点端口失败。"
            return 1
        }
    fi
}

_replace_port_in_text() {
    local text="$1" old_port="$2" new_port="$3"
    printf '%s' "$text" | sed "s/:${old_port}/:${new_port}/g; s/-${old_port}/-${new_port}/g"
}

_build_protocol_share_link() {
    local tag="$1" protocol
    protocol=$(_get_meta_field "$tag" protocol)
    case "$protocol" in
        ss2022_reality) _build_ss2022_reality_link "$tag" ;;
        trojan_reality) _build_trojan_reality_link "$tag" ;;
        vmess_reality) _build_vmess_reality_link "$tag" ;;
        vless_vision_reality) _build_vless_vision_reality_link "$tag" ;;
        anytls_reality) _build_anytls_reality_link "$tag" ;;
        *) return 1 ;;
    esac
}

_get_share_link() {
    local tag="$1" saved_link built_link
    saved_link=$(_get_meta_field "$tag" qx_link)
    [ -n "$saved_link" ] && { echo "$saved_link"; return 0; }
    built_link=$(_build_protocol_share_link "$tag" 2>/dev/null)
    [ -n "$built_link" ] && { echo "$built_link"; return 0; }
    return 1
}

_show_share_link() {
    local tag="$1" title="${2:-Quantumult X}" link
    link=$(_get_share_link "$tag")
    [ -n "$link" ] || { _warn "未能生成分享链接。"; return 1; }
    echo ""
    echo -e "  ${YELLOW}${title}:${NC} ${link}"
    echo ""
}

_finalize_added_node() {
    local protocol_label="$1" name="$2" tag="$3"
    _manage_xray_service restart
    _success "${protocol_label} 节点添加完成：${name}。"
    _show_share_link "$tag"
    if [ "$(_protocol_of_tag "$tag")" = "vless_vision_reality" ]; then
        echo -e "  ${YELLOW}标准分享链接:${NC} $(_build_vless_vision_reality_std_link "$tag")"
        echo ""
    fi
}

_protocol_of_tag() {
    _get_meta_field "$1" protocol
}

_generate_singbox_reality_keys() {
    local keypair
    keypair=$($SINGBOX_BIN generate reality-keypair 2>&1)
    SINGBOX_REALITY_PRIVATE_KEY=$(echo "$keypair" | awk '/PrivateKey/ {print $2}')
    SINGBOX_REALITY_PUBLIC_KEY=$(echo "$keypair" | awk '/PublicKey/ {print $2}')
    SINGBOX_REALITY_SHORT_ID=$($SINGBOX_BIN generate rand --hex 8 2>/dev/null)
    [ -n "$SINGBOX_REALITY_SHORT_ID" ] || SINGBOX_REALITY_SHORT_ID=$(openssl rand -hex 8)

    if [ -z "$SINGBOX_REALITY_PRIVATE_KEY" ] || [ -z "$SINGBOX_REALITY_PUBLIC_KEY" ]; then
        _error "Sing-box Reality 密钥生成失败。"
        echo "$keypair" >&2
        return 1
    fi
}

_get_singbox_meta_field() {
    local tag="$1" field="$2"
    jq --arg tag "$tag" --arg field "$field" -r '.[$tag][$field] // empty' "$META_FILE" 2>/dev/null
}

_build_anytls_reality_link() {
    local tag="$1"
    local port name password sni public_key short_id server_ip link_ip

    port=$(jq --arg tag "$tag" -r '.inbounds[] | select(.tag == $tag) | .listen_port // empty' "$SINGBOX_CONFIG" 2>/dev/null)
    [ -n "$port" ] || return 1

    name=$(_get_tag_name "$tag")
    password=$(_get_singbox_meta_field "$tag" password)
    sni=$(_get_singbox_meta_field "$tag" sni)
    public_key=$(_get_singbox_meta_field "$tag" publicKey)
    short_id=$(_get_singbox_meta_field "$tag" shortId)
    server_ip=$(_get_singbox_meta_field "$tag" server)

    [ -n "$password" ] || return 1
    [ -n "$sni" ] || return 1
    [ -n "$public_key" ] || return 1
    [ -n "$short_id" ] || return 1
    [ -n "$server_ip" ] || return 1

    link_ip="$server_ip"
    [[ "$link_ip" == *":"* ]] && link_ip="[$link_ip]"
    printf 'anytls=%s:%s, password=%s, over-tls=true, tls-host=%s, tls-verification=true, reality-base64-pubkey=%s, reality-hex-shortid=%s, udp-relay=true, tag=%s\n' \
        "$link_ip" "$port" "$password" "$sni" "$public_key" "$short_id" "$name"
}

_finalize_added_singbox_node() {
    local protocol_label="$1" name="$2" tag="$3"
    _manage_singbox_service restart
    _success "${protocol_label} 节点添加完成：${name}。"
    echo ""
    echo -e "  ${YELLOW}Quantumult X:${NC} $(_build_anytls_reality_link "$tag")"
    echo ""
}

_protocol_name() {
    case "$1" in
        ss2022_reality) echo "SS2022 + Reality" ;;
        trojan_reality) echo "Trojan + Reality" ;;
        vmess_reality) echo "Vmess + Reality" ;;
        vless_vision_reality) echo "VLESS + Vision + Reality" ;;
        anytls_reality) echo "AnyTLS + Reality" ;;
        *) echo "$1" ;;
    esac
}

_protocol_default_name() {
    local protocol="$1" port="$2"
    case "$protocol" in
        ss2022_reality) printf 'SS2022-REALITY-%s\n' "$port" ;;
        trojan_reality) printf 'TROJAN-REALITY-%s\n' "$port" ;;
        vmess_reality) printf 'VMESS-REALITY-%s\n' "$port" ;;
        vless_vision_reality) printf 'VLESS-REALITY-VISION-%s\n' "$port" ;;
        anytls_reality) printf 'ANYTLS-REALITY-%s\n' "$port" ;;
        *) printf '%s-%s\n' "$protocol" "$port" ;;
    esac
}

_protocol_add_node() {
    local protocol="$1"
    case "$protocol" in
        ss2022_reality) _add_ss2022_reality ;;
        trojan_reality) _add_trojan_reality ;;
        vmess_reality) _add_vmess_reality ;;
        vless_vision_reality) _add_vless_vision_reality ;;
        anytls_reality) _add_anytls_reality ;;
        *) _error "暂不支持的协议: $protocol"; return 1 ;;
    esac
}

_protocol_view_all_nodes() {
    if ! _has_nodes; then
        _warn "当前没有节点。"
        return
    fi

    echo ""
    echo -e "${YELLOW}══════════════════ 节点列表 ══════════════════${NC}"
    local count=0 tag port name link display_proto std_link
    while IFS= read -r tag; do
        count=$((count + 1))
        port=$(_get_inbound_port "$tag")
        name=$(_get_tag_name "$tag")
        link=$(_get_share_link "$tag")
        display_proto=$(_get_inbound_display_protocol "$tag")
        echo ""
        echo -e "  ${GREEN}[${count}]${NC} ${CYAN}${name}${NC}"
        echo -e "      类型: ${YELLOW}$(_protocol_name "$(_protocol_of_tag "$tag")")${NC}"
        echo -e "      协议: ${YELLOW}${display_proto}${NC}  |  端口: ${GREEN}${port}${NC}  |  标签: ${CYAN}${tag}${NC}"
        if [ -n "$link" ]; then
            echo -e "      ${YELLOW}Quantumult X:${NC} ${link}"
        else
            echo -e "      ${RED}Quantumult X: 无法生成链接${NC}"
        fi
        if [ "$(_protocol_of_tag "$tag")" = "vless_vision_reality" ]; then
            std_link=$(_build_vless_vision_reality_std_link "$tag")
            [ -n "$std_link" ] && echo -e "      ${YELLOW}标准分享链接:${NC} ${std_link}"
        fi
    done < <(_list_tags)
}

_restart_node_backend() {
    local tag="$1" protocol
    protocol=$(_get_meta_field "$tag" protocol)
    if [ "$protocol" = "anytls_reality" ]; then
        _manage_singbox_service restart
    else
        _manage_xray_service restart
    fi
}

_protocol_view_one_node_by_tag() {
    local target_tag="$1" port name link display_proto std_link
    [ -n "$target_tag" ] || return 1
    port=$(_get_inbound_port "$target_tag")
    name=$(_get_tag_name "$target_tag")
    link=$(_get_share_link "$target_tag")
    display_proto=$(_get_inbound_display_protocol "$target_tag")

    echo ""
    echo -e "${YELLOW}══════════════════ 节点详情 ══════════════════${NC}"
    echo -e "  名称: ${CYAN}${name}${NC}"
    echo -e "  类型: ${YELLOW}$(_protocol_name "$(_protocol_of_tag "$target_tag")")${NC}"
    echo -e "  协议: ${YELLOW}${display_proto}${NC}"
    echo -e "  端口: ${GREEN}${port}${NC}"
    echo -e "  标签: ${CYAN}${target_tag}${NC}"
    if [ -n "$link" ]; then
        echo -e "  ${YELLOW}Quantumult X:${NC} ${link}"
    else
        echo -e "  ${RED}Quantumult X: 无法生成链接${NC}"
    fi
    if [ "$(_protocol_of_tag "$target_tag")" = "vless_vision_reality" ]; then
        std_link=$(_build_vless_vision_reality_std_link "$target_tag")
        [ -n "$std_link" ] && echo -e "  ${YELLOW}标准分享链接:${NC} ${std_link}"
    fi
    echo ""
}

_protocol_view_nodes() {
    local choice i=1
    local -a tags
    if ! _has_nodes; then
        _warn "当前没有节点。"
        return
    fi

    mapfile -t tags < <(_list_tags)
    [ "${#tags[@]}" -gt 0 ] || { _warn "当前没有节点。"; return; }

    echo ""
    echo -e "${YELLOW}══════════ 查看节点 ══════════${NC}"
    for tag in "${tags[@]}"; do
        echo -e "  ${GREEN}[${i}]${NC} $(_get_tag_name "$tag") (端口: $(_get_inbound_port "$tag"))"
        i=$((i + 1))
    done
    echo -e "  ${GREEN}[a]${NC} 查看全部节点"
    echo -e "  ${RED}[0]${NC} 返回"
    echo ""
    read -p "请选择 [0-${#tags[@]}/a]: " choice

    case "$choice" in
        a|A) _protocol_view_all_nodes ;;
        0) return 0 ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#tags[@]}" ]; then
                _protocol_view_one_node_by_tag "${tags[$((choice-1))]}"
            else
                _error "无效输入。"
                return 1
            fi
            ;;
    esac
}

_protocol_delete_node() {
    if ! _has_nodes; then
        _warn "当前没有节点。"
        return
    fi

    local target_tag target_name confirm
    target_tag=$(_select_tag "══════════ 选择要删除的节点 ══════════") || return
    target_name=$(_get_tag_name "$target_tag")
    read -p "确定删除 [${target_name}]? (y/N): " confirm
    _confirm_yes "$confirm" || { _info "已取消。"; return; }

    _delete_inbound_by_tag "$target_tag" || return 1
    _atomic_modify_json "$META_FILE" "del(.\"$target_tag\")" >/dev/null 2>&1 || true
    _restart_node_backend "$target_tag"
    _success "节点删除完成：${target_name}。"
}

_protocol_modify_port() {
    if ! _has_nodes; then
        _warn "当前没有节点。"
        return
    fi

    local target_tag old_port target_name new_port new_tag new_name old_link new_link tmp
    target_tag=$(_select_tag "══════════ 选择要修改端口的节点 ══════════") || return
    old_port=$(_get_inbound_port "$target_tag")
    target_name=$(_get_tag_name "$target_tag")

    [ -n "$old_port" ] && [ "$old_port" != "null" ] || { _error "未找到目标节点端口。"; return 1; }

    _info "当前端口: ${old_port}"
    new_port=$(_input_port)
    [ "$new_port" = "$old_port" ] && { _info "新端口与当前端口一致，无需修改。"; return 0; }

    new_tag=$(printf '%s' "$target_tag" | sed "s/${old_port}/${new_port}/g")
    new_name=$(printf '%s' "$target_name" | sed "s/${old_port}/${new_port}/g")
    [ -n "$new_tag" ] || new_tag="$target_tag"
    [ -n "$new_name" ] || new_name="$target_name"

    if [ "$new_tag" != "$target_tag" ] && _list_tags | grep -Fxq "$new_tag"; then
        _error "修改后的节点标签已存在，请调整节点名称后再试。"
        return 1
    fi

    old_link=$(_get_share_link "$target_tag")
    _update_inbound_port_and_tag "$target_tag" "$new_port" "$new_tag" || return 1

    new_link=$(_replace_port_in_text "$old_link" "$old_port" "$new_port")
    [ -n "$new_link" ] || new_link=$(_build_protocol_share_link "$new_tag" 2>/dev/null)
    tmp="${META_FILE}.tmp.$$"
    jq --arg ot "$target_tag" --arg nt "$new_tag" --arg n "$new_name" --arg l "$new_link" '. + {($nt): ((.[$ot] // {}) + {name: $n, qx_link: $l})} | del(.[$ot])' "$META_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$META_FILE" || {
        rm -f "$tmp"
        _error "更新节点元数据失败。"
        return 1
    }

    _restart_node_backend "$new_tag"
    _success "节点端口修改完成：${new_name} -> ${new_port}。"
}

# ===================== 协议实现：SS2022 + Reality =====================

_ss2022_reality_method() {
    echo "2022-blake3-aes-128-gcm"
}

_ss2022_reality_password() {
    openssl rand -base64 16
}

_build_ss2022_reality_inbound() {
    local tag="$1" port="$2" method="$3" password="$4" sni="$5" private_key="$6" short_id="$7"
    local stream
    stream=$(_build_reality_stream "raw" "$sni" "$private_key" "$short_id")

    jq -n --arg tag "$tag" --argjson port "$port" --arg method "$method" --arg password "$password" --argjson stream "$stream" '
        {
            "tag": $tag,
            "listen": "::",
            "port": $port,
            "protocol": "shadowsocks",
            "settings": {
                "method": $method,
                "password": $password,
                "network": "tcp,udp"
            },
            "streamSettings": $stream
        }'
}

_build_ss2022_reality_link() {
    local tag="$1"
    local port name method password sni public_key short_id server_ip link_ip

    port=$(_get_inbound_field "$tag" '.port')
    [ -n "$port" ] || return 1

    name=$(_get_tag_name "$tag")
    method=$(_get_meta_field "$tag" method)
    password=$(_get_meta_field "$tag" password)
    sni=$(_get_meta_field "$tag" sni)
    public_key=$(_get_meta_field "$tag" publicKey)
    short_id=$(_get_meta_field "$tag" shortId)
    server_ip=$(_get_meta_field "$tag" server)

    [ -n "$method" ] || return 1
    [ -n "$password" ] || return 1
    [ -n "$sni" ] || return 1
    [ -n "$public_key" ] || return 1
    [ -n "$short_id" ] || return 1
    [ -n "$server_ip" ] || return 1

    link_ip="$server_ip"
    [[ "$link_ip" == *":"* ]] && link_ip="[$link_ip]"
    printf 'shadowsocks=%s:%s, method=%s, password=%s, obfs=over-tls, obfs-host=%s, tls-verification=true, reality-base64-pubkey=%s, reality-hex-shortid=%s, udp-relay=true, tag=%s\n' \
        "$link_ip" "$port" "$method" "$password" "$sni" "$public_key" "$short_id" "$name"
}

_add_ss2022_reality() {
    local protocol node_ip port sni name tag method password inbound qx_link
    protocol="ss2022_reality"

    node_ip=$(_input_node_ip)
    port=$(_input_port)
    sni=$(_input_sni "$DEFAULT_SNI")

    method=$(_ss2022_reality_method)
    password=$(_ss2022_reality_password)
    _generate_reality_keys || return 1

    name=$(_input_node_name "$protocol" "$port") || return 1
    tag="$name"

    inbound=$(_build_ss2022_reality_inbound "$tag" "$port" "$method" "$password" "$sni" "$REALITY_PRIVATE_KEY" "$REALITY_SHORT_ID")
    _atomic_modify_json "$XRAY_CONFIG" ".inbounds += [$inbound]" || return 1

    qx_link=$(_build_ss2022_reality_link "$tag" 2>/dev/null)
    _save_meta_bundle "$tag" "$name" "$qx_link" \
        "protocol=${protocol}" \
        "password=${password}" \
        "publicKey=${REALITY_PUBLIC_KEY}" \
        "shortId=${REALITY_SHORT_ID}" \
        "server=${node_ip}" \
        "sni=${sni}" \
        "method=${method}"

    _finalize_added_node "SS2022+Reality" "$name" "$tag"
}

# ===================== 协议实现：Trojan + Reality =====================

_trojan_reality_password() {
    local custom_password
    read -p "请输入 Trojan 密码 (回车自动生成): " custom_password
    if [ -n "$custom_password" ]; then
        printf '%s\n' "$custom_password"
    else
        openssl rand -base64 16
    fi
}

_build_trojan_reality_inbound() {
    local tag="$1" port="$2" password="$3" sni="$4" private_key="$5" short_id="$6"
    local stream
    stream=$(_build_reality_stream "raw" "$sni" "$private_key" "$short_id")

    jq -n --arg tag "$tag" --argjson port "$port" --arg password "$password" --argjson stream "$stream" '
        {
            "tag": $tag,
            "listen": "::",
            "port": $port,
            "protocol": "trojan",
            "settings": {
                "clients": [
                    {
                        "password": $password
                    }
                ]
            },
            "streamSettings": $stream
        }'
}

_build_trojan_reality_link() {
    local tag="$1"
    local port name password sni public_key short_id server_ip link_ip

    port=$(_get_inbound_field "$tag" '.port')
    [ -n "$port" ] || return 1

    name=$(_get_tag_name "$tag")
    password=$(_get_meta_field "$tag" password)
    sni=$(_get_meta_field "$tag" sni)
    public_key=$(_get_meta_field "$tag" publicKey)
    short_id=$(_get_meta_field "$tag" shortId)
    server_ip=$(_get_meta_field "$tag" server)

    [ -n "$password" ] || return 1
    [ -n "$sni" ] || return 1
    [ -n "$public_key" ] || return 1
    [ -n "$short_id" ] || return 1
    [ -n "$server_ip" ] || return 1

    link_ip="$server_ip"
    [[ "$link_ip" == *":"* ]] && link_ip="[$link_ip]"
    printf 'trojan=%s:%s, password=%s, over-tls=true, tls-host=%s, tls-verification=true, reality-base64-pubkey=%s, reality-hex-shortid=%s, udp-relay=true, tag=%s\n' \
        "$link_ip" "$port" "$password" "$sni" "$public_key" "$short_id" "$name"
}

_add_trojan_reality() {
    local protocol node_ip port sni name tag password inbound qx_link
    protocol="trojan_reality"

    node_ip=$(_input_node_ip)
    port=$(_input_port)
    sni=$(_input_sni "$DEFAULT_SNI")

    password=$(_trojan_reality_password)
    _generate_reality_keys || return 1

    name=$(_input_node_name "$protocol" "$port") || return 1
    tag="$name"

    inbound=$(_build_trojan_reality_inbound "$tag" "$port" "$password" "$sni" "$REALITY_PRIVATE_KEY" "$REALITY_SHORT_ID")
    _atomic_modify_json "$XRAY_CONFIG" ".inbounds += [$inbound]" || return 1

    qx_link=$(_build_trojan_reality_link "$tag" 2>/dev/null)
    _save_meta_bundle "$tag" "$name" "$qx_link" \
        "protocol=${protocol}" \
        "password=${password}" \
        "publicKey=${REALITY_PUBLIC_KEY}" \
        "shortId=${REALITY_SHORT_ID}" \
        "server=${node_ip}" \
        "sni=${sni}"

    _finalize_added_node "Trojan+Reality" "$name" "$tag"
}

# ===================== 协议实现：Vmess + Reality =====================

_build_vmess_reality_inbound() {
    local tag="$1" port="$2" uuid="$3" sni="$4" private_key="$5" short_id="$6"
    local stream
    stream=$(_build_reality_stream "raw" "$sni" "$private_key" "$short_id")

    jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --argjson stream "$stream" '
        {
            "tag": $tag,
            "listen": "::",
            "port": $port,
            "protocol": "vmess",
            "settings": {
                "clients": [
                    {
                        "id": $uuid
                    }
                ]
            },
            "streamSettings": $stream
        }'
}

_build_vmess_reality_link() {
    local tag="$1"
    local port name uuid sni public_key short_id server_ip link_ip

    port=$(_get_inbound_field "$tag" '.port')
    [ -n "$port" ] || return 1

    name=$(_get_tag_name "$tag")
    uuid=$(_get_meta_field "$tag" uuid)
    sni=$(_get_meta_field "$tag" sni)
    public_key=$(_get_meta_field "$tag" publicKey)
    short_id=$(_get_meta_field "$tag" shortId)
    server_ip=$(_get_meta_field "$tag" server)

    [ -n "$uuid" ] || return 1
    [ -n "$sni" ] || return 1
    [ -n "$public_key" ] || return 1
    [ -n "$short_id" ] || return 1
    [ -n "$server_ip" ] || return 1

    link_ip="$server_ip"
    [[ "$link_ip" == *":"* ]] && link_ip="[$link_ip]"
    printf 'vmess=%s:%s, method=none, password=%s, obfs=over-tls, obfs-host=%s, tls-verification=true, reality-base64-pubkey=%s, reality-hex-shortid=%s, udp-relay=true, tag=%s\n' \
        "$link_ip" "$port" "$uuid" "$sni" "$public_key" "$short_id" "$name"
}

_add_vmess_reality() {
    local protocol node_ip port sni name tag uuid inbound qx_link
    protocol="vmess_reality"

    node_ip=$(_input_node_ip)
    port=$(_input_port)
    sni=$(_input_sni "$DEFAULT_SNI")

    uuid=$(_input_uuid)
    _generate_reality_keys || return 1

    name=$(_input_node_name "$protocol" "$port") || return 1
    tag="$name"

    inbound=$(_build_vmess_reality_inbound "$tag" "$port" "$uuid" "$sni" "$REALITY_PRIVATE_KEY" "$REALITY_SHORT_ID")
    _atomic_modify_json "$XRAY_CONFIG" ".inbounds += [$inbound]" || return 1

    qx_link=$(_build_vmess_reality_link "$tag" 2>/dev/null)
    _save_meta_bundle "$tag" "$name" "$qx_link" \
        "protocol=${protocol}" \
        "uuid=${uuid}" \
        "publicKey=${REALITY_PUBLIC_KEY}" \
        "shortId=${REALITY_SHORT_ID}" \
        "server=${node_ip}" \
        "sni=${sni}"

    _finalize_added_node "Vmess+Reality" "$name" "$tag"
}

# ===================== 协议实现：VLESS + XTLS-RPRX-Vision + Reality =====================

_build_vless_vision_reality_inbound() {
    local tag="$1" port="$2" uuid="$3" sni="$4" private_key="$5" short_id="$6"
    local stream
    stream=$(_build_reality_stream "raw" "$sni" "$private_key" "$short_id")

    jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --argjson stream "$stream" '
        {
            "tag": $tag,
            "listen": "::",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": $uuid,
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": $stream
        }'
}

_build_vless_vision_reality_std_link() {
    local tag="$1"
    local port name uuid sni public_key short_id server_ip link_ip encoded_name

    port=$(_get_inbound_field "$tag" '.port')
    [ -n "$port" ] || return 1

    name=$(_get_tag_name "$tag")
    uuid=$(_get_meta_field "$tag" uuid)
    sni=$(_get_meta_field "$tag" sni)
    public_key=$(_get_meta_field "$tag" publicKey)
    short_id=$(_get_meta_field "$tag" shortId)
    server_ip=$(_get_meta_field "$tag" server)

    [ -n "$uuid" ] || return 1
    [ -n "$sni" ] || return 1
    [ -n "$public_key" ] || return 1
    [ -n "$short_id" ] || return 1
    [ -n "$server_ip" ] || return 1

    link_ip="$server_ip"
    [[ "$link_ip" == *":"* ]] && link_ip="[$link_ip]"
    encoded_name=$(printf '%s' "$name" | sed 's/%/%25/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g; s/&/%26/g; s/+/%2B/g')
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "$uuid" "$link_ip" "$port" "$sni" "$public_key" "$short_id" "$encoded_name"
}

_build_vless_vision_reality_link() {
    local tag="$1"
    local port name uuid sni public_key short_id server_ip link_ip

    port=$(_get_inbound_field "$tag" '.port')
    [ -n "$port" ] || return 1

    name=$(_get_tag_name "$tag")
    uuid=$(_get_meta_field "$tag" uuid)
    sni=$(_get_meta_field "$tag" sni)
    public_key=$(_get_meta_field "$tag" publicKey)
    short_id=$(_get_meta_field "$tag" shortId)
    server_ip=$(_get_meta_field "$tag" server)

    [ -n "$uuid" ] || return 1
    [ -n "$sni" ] || return 1
    [ -n "$public_key" ] || return 1
    [ -n "$short_id" ] || return 1
    [ -n "$server_ip" ] || return 1

    link_ip="$server_ip"
    [[ "$link_ip" == *":"* ]] && link_ip="[$link_ip]"
    printf 'vless=%s:%s, method=none, password=%s, obfs=over-tls, obfs-host=%s, tls-verification=true, reality-base64-pubkey=%s, reality-hex-shortid=%s, udp-relay=true, vless-flow=xtls-rprx-vision, tag=%s\n' \
        "$link_ip" "$port" "$uuid" "$sni" "$public_key" "$short_id" "$name"
}

_add_vless_vision_reality() {
    local protocol node_ip port sni name tag uuid inbound qx_link
    protocol="vless_vision_reality"

    node_ip=$(_input_node_ip)
    port=$(_input_port)
    sni=$(_input_sni "$DEFAULT_SNI")

    uuid=$(_input_uuid)
    _generate_reality_keys || return 1

    name=$(_input_node_name "$protocol" "$port") || return 1
    tag="$name"

    inbound=$(_build_vless_vision_reality_inbound "$tag" "$port" "$uuid" "$sni" "$REALITY_PRIVATE_KEY" "$REALITY_SHORT_ID")
    _atomic_modify_json "$XRAY_CONFIG" ".inbounds += [$inbound]" || return 1

    qx_link=$(_build_vless_vision_reality_link "$tag" 2>/dev/null)
    _save_meta_bundle "$tag" "$name" "$qx_link" \
        "protocol=${protocol}" \
        "uuid=${uuid}" \
        "publicKey=${REALITY_PUBLIC_KEY}" \
        "shortId=${REALITY_SHORT_ID}" \
        "server=${node_ip}" \
        "sni=${sni}"

    _finalize_added_node "VLESS+Vision+Reality" "$name" "$tag"
}

# ===================== 协议实现：AnyTLS + Reality (Sing-box) =====================

_anytls_reality_password() {
    local custom_password
    read -p "请输入 AnyTLS 密码 (回车自动生成): " custom_password
    if [ -n "$custom_password" ]; then
        printf '%s\n' "$custom_password"
    else
        openssl rand -base64 16
    fi
}

_build_anytls_reality_inbound() {
    local tag="$1" port="$2" password="$3" sni="$4" private_key="$5" short_id="$6"
    jq -n --arg t "$tag" --argjson p "$port" --arg pwd "$password" --arg sn "$sni" --arg pk "$private_key" --arg sid "$short_id" '
        {
          "type": "anytls",
          "tag": $t,
          "listen": "::",
          "listen_port": $p,
          "users": [
            {
              "name": $t,
              "password": $pwd
            }
          ],
          "tls": {
            "enabled": true,
            "reality": {
              "enabled": true,
              "handshake": {
                "server": $sn,
                "server_port": 443
              },
              "private_key": $pk,
              "short_id": [
                $sid
              ]
            }
          }
        }'
}

_add_anytls_reality() {
    local protocol node_ip port sni name tag password inbound qx_link
    protocol="anytls_reality"

    if [ ! -x "$SINGBOX_BIN" ]; then
        _warn "当前未安装 Sing-box 内核。"
        _warn "AnyTLS + Reality 需要先安装 Sing-box 核心。"
        _warn "请先执行 [2] 安装/更新 Sing-box 核心。"
        return 1
    fi

    node_ip=$(_input_node_ip)
    port=$(_input_port)
    sni=$(_input_sni "$DEFAULT_SNI")

    password=$(_anytls_reality_password)
    _generate_singbox_reality_keys || return 1

    name=$(_input_node_name "$protocol" "$port") || return 1
    tag="$name"

    _init_singbox_config
    inbound=$(_build_anytls_reality_inbound "$tag" "$port" "$password" "$sni" "$SINGBOX_REALITY_PRIVATE_KEY" "$SINGBOX_REALITY_SHORT_ID")
    _atomic_modify_json "$SINGBOX_CONFIG" ".inbounds += [$inbound]" || return 1

    qx_link=$(_build_anytls_reality_link "$tag" 2>/dev/null)
    _save_meta_bundle "$tag" "$name" "$qx_link" \
        "protocol=${protocol}" \
        "password=${password}" \
        "publicKey=${SINGBOX_REALITY_PUBLIC_KEY}" \
        "shortId=${SINGBOX_REALITY_SHORT_ID}" \
        "server=${node_ip}" \
        "sni=${sni}"

    _finalize_added_singbox_node "AnyTLS+Reality" "$name" "$tag"
}

# ===================== 预留协议模板（示例） =====================

# 后续新增协议时，按下面模式补充即可：
# 1. _add_xxx
# 2. _build_xxx_inbound
# 3. _build_xxx_link
# 4. 在 _protocol_add_node / _build_protocol_share_link / _protocol_name 中注册

# ===================== 菜单与入口 =====================

_add_protocol_menu() {
    local choice
    echo ""
    echo -e "${YELLOW}══════════ 选择要添加的协议 ══════════${NC}"
    echo -e " ${CYAN}【Xray 内核】${NC}"
    echo -e "  ${GREEN}[1]${NC} VLESS + Vision + Reality"
    echo -e "  ${GREEN}[2]${NC} SS2022 + Reality"
    echo -e "  ${GREEN}[3]${NC} Trojan + Reality"
    echo -e "  ${GREEN}[4]${NC} Vmess + Reality"
    echo ""
    echo -e " ${CYAN}【Sing-box 内核】${NC}"
    echo -e "  ${GREEN}[5]${NC} AnyTLS + Reality"
    echo -e "  ${RED}[0]${NC} 返回上一级"
    echo ""
    read -p "请选择 [0-5]: " choice

    case "$choice" in
        1|2|3|4)
            _require_xray || return 1
            _init_xray_config
            case "$choice" in
                1) _protocol_add_node vless_vision_reality ;;
                2) _protocol_add_node ss2022_reality ;;
                3) _protocol_add_node trojan_reality ;;
                4) _protocol_add_node vmess_reality ;;
            esac
            ;;
        5)
            _require_singbox || return 1
            _protocol_add_node anytls_reality
            ;;
        0) return 0 ;;
        *) _error "无效输入。"; return 1 ;;
    esac
}

_xray_menu() {
    while true; do
        clear
        echo ""
        echo -e "=================================================="
        echo -e " XTLS Reality 协议管理脚本 v${SCRIPT_VERSION}"
        echo -e " 当前协议组合: Xray + Sing-box / Reality"
        _show_xray_runtime_summary
        echo -e "=================================================="
        echo -e " ${CYAN}【核心管理】${NC}"
        _menu_item 1  "安装/更新 Xray 内核"
        _menu_item 2  "安装/更新 Sing-box 核心"
        echo ""
        echo -e " ${CYAN}【Xray 服务管理】${NC}"
        _menu_item 3  "启动 Xray 服务"
        _menu_item 4  "停止 Xray 服务"
        _menu_item 5  "重启 Xray 服务"
        echo ""
        echo -e " ${CYAN}【Sing-box 服务管理】${NC}"
        _menu_item 6  "启动 Sing-box 服务"
        _menu_item 7  "停止 Sing-box 服务"
        _menu_item 8  "重启 Sing-box 服务"
        echo ""
        echo -e " ${CYAN}【节点管理】${NC}"
        _menu_item 9  "添加节点（选择协议）"
        _menu_item 10 "查看节点"
        _menu_item 11 "删除节点"
        _menu_item 12 "修改节点端口"
        _menu_item 13 "设置网络优先级 (IPv4/IPv6)"
        echo ""
        echo -e " ${CYAN}【脚本与卸载】${NC}"
        _menu_danger 55 "更新脚本"
        _menu_danger 77 "卸载 Sing-box 内核"
        _menu_danger 88 "卸载 Xray 内核"
        _menu_danger 99 "卸载脚本"
        _menu_exit 0 "退出脚本"
        echo -e "=================================================="
        read -p "请选择 [0-99]: " choice

        case "$choice" in
            1) _install_or_update_xray; _pause ;;
            2) _install_or_update_singbox; _pause ;;
            3) [ -f "$XRAY_BIN" ] && _manage_xray_service start; _pause ;;
            4) [ -f "$XRAY_BIN" ] && _manage_xray_service stop; _pause ;;
            5) [ -f "$XRAY_BIN" ] && _manage_xray_service restart; _pause ;;
            6) [ -f "$SINGBOX_BIN" ] && _manage_singbox_service start; _pause ;;
            7) [ -f "$SINGBOX_BIN" ] && _manage_singbox_service stop; _pause ;;
            8) [ -f "$SINGBOX_BIN" ] && _manage_singbox_service restart; _pause ;;
            9) _add_protocol_menu; _pause ;;
            10) _protocol_view_nodes; _pause ;;
            11) _protocol_delete_node; _pause ;;
            12) _protocol_modify_port; _pause ;;
            13) _choose_ip_preference ;;
            55) _update_script_self; _pause; exit 0 ;;
            77) _uninstall_singbox; _pause ;;
            88) _uninstall_xray; _pause ;;
            99) _uninstall_script ;;
            0) exit 0 ;;
            *) _error "无效输入。"; _pause ;;
        esac
    done
}

_main() {
    _check_root
    _detect_init_system
    _ensure_deps
    _install_script_shortcut
    if [ -f "$XRAY_BIN" ]; then
        _init_xray_config
        _create_xray_service >/dev/null 2>&1 || true
    fi
    _xray_menu
}

_main "$@"
