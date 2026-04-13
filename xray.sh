#!/bin/bash

# ============================================================
#      Xray SS2022 + Reality 独立安装管理脚本 (单协议版)
# ============================================================

SCRIPT_VERSION="2.2"
SCRIPT_CMD_NAME="ss2022"
SCRIPT_CMD_ALIAS="SS2022"
SCRIPT_INSTALL_PATH="/usr/local/bin/${SCRIPT_CMD_NAME}"
SCRIPT_ALIAS_PATH="/usr/local/bin/${SCRIPT_CMD_ALIAS}"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/Ezrea7/SS2022-Reality/refs/heads/main/xray.sh"
SELF_SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_METADATA="${XRAY_DIR}/metadata.json"
XRAY_LOG="/var/log/xray.log"
XRAY_PID_FILE="/tmp/xray.pid"
DEFAULT_SNI="www.amd.com"

# IP preference configuration file used to determine whether IPv4 or IPv6 should
# be attempted first when detecting the server's public address. Possible
# values are "ipv4" or "ipv6". If this file does not exist or contains an
# invalid value, the default is "ipv4".
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

trap 'rm -f "${XRAY_DIR}"/*.tmp.* 2>/dev/null || true' EXIT

_pause() {
    [ -t 0 ] || return 0
    echo ""
    read -p "按回车键继续..." _
}

_menu_item() {
    printf "  ${GREEN}[%-2s]${NC} %s\n" "$1" "$2"
}

_menu_danger() {
    printf "  ${RED}[%-2s]${NC} %s\n" "$1" "$2"
}

_menu_exit() {
    printf "  ${YELLOW}[%-2s]${NC} %s\n" "$1" "$2"
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

_pkg_install() {
    [ $# -eq 0 ] && return 0
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$@" >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@" >/dev/null 2>&1
    fi
}

_ensure_deps() {
    local missing still_missing c
    missing=""
    for c in bash jq openssl awk sed grep; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing="$missing curl"
    command -v unzip >/dev/null 2>&1 || missing="$missing unzip"
    command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || _pkg_install iproute2 net-tools
    if command -v apk >/dev/null 2>&1; then
        [ -f /etc/ssl/certs/ca-certificates.crt ] || missing="$missing ca-certificates"
    fi
    [ -n "$missing" ] && _pkg_install $missing

    still_missing=""
    for c in bash jq openssl awk sed grep unzip; do
        command -v "$c" >/dev/null 2>&1 || still_missing="$still_missing $c"
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || still_missing="$still_missing curl"
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

    if [ "$src" != "$SCRIPT_INSTALL_PATH" ]; then
        cp -f "$src" "$SCRIPT_INSTALL_PATH" 2>/dev/null || return 0
    fi
    chmod +x "$SCRIPT_INSTALL_PATH" 2>/dev/null || true

    ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH" 2>/dev/null || cp -f "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_ALIAS_PATH" 2>/dev/null || true
}

_update_script_self() {
    local tmp="/tmp/${SCRIPT_CMD_NAME}.update.$$"
    local src
    src="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

    if command -v curl >/dev/null 2>&1; then
        curl -LfsS "$SCRIPT_UPDATE_URL" -o "$tmp" 2>/dev/null || {
            rm -f "$tmp"
            _error "下载更新失败。"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$SCRIPT_UPDATE_URL" -O "$tmp" 2>/dev/null || {
            rm -f "$tmp"
            _error "下载更新失败。"
            return 1
        }
    else
        _error "未找到 curl/wget，无法更新脚本。"
        return 1
    fi

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

    _success "脚本已更新。当前快捷命令: ${SCRIPT_CMD_NAME} / ${SCRIPT_CMD_ALIAS}"
    _warn "请重新运行 ${SCRIPT_CMD_NAME} 或 ${SCRIPT_CMD_ALIAS} 以加载新版本。"
}

_get_public_ip() {
    [ -n "$server_ip" ] && { echo "$server_ip"; return; }
    local ip="" pref
    pref=$(_get_ip_preference)
    if command -v curl >/dev/null 2>&1; then
        if [ "$pref" = "ipv6" ]; then
            ip=$(curl -s6 --max-time 3 api6.ipify.org 2>/dev/null || curl -s6 --max-time 3 icanhazip.com 2>/dev/null)
            [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 api.ipify.org 2>/dev/null || curl -s4 --max-time 3 icanhazip.com 2>/dev/null)
        else
            ip=$(curl -s4 --max-time 3 api.ipify.org 2>/dev/null || curl -s4 --max-time 3 icanhazip.com 2>/dev/null)
            [ -z "$ip" ] && ip=$(curl -s6 --max-time 3 api6.ipify.org 2>/dev/null || curl -s6 --max-time 3 icanhazip.com 2>/dev/null)
        fi
    fi
    if [ -z "$ip" ] && command -v wget >/dev/null 2>&1; then
        if [ "$pref" = "ipv6" ]; then
            ip=$(wget -qO- -6 --timeout=3 api6.ipify.org 2>/dev/null || wget -qO- -6 --timeout=3 icanhazip.com 2>/dev/null)
            [ -z "$ip" ] && ip=$(wget -qO- -4 --timeout=3 api.ipify.org 2>/dev/null || wget -qO- -4 --timeout=3 icanhazip.com 2>/dev/null)
        else
            ip=$(wget -qO- -4 --timeout=3 api.ipify.org 2>/dev/null || wget -qO- -4 --timeout=3 icanhazip.com 2>/dev/null)
            [ -z "$ip" ] && ip=$(wget -qO- -6 --timeout=3 api6.ipify.org 2>/dev/null || wget -qO- -6 --timeout=3 icanhazip.com 2>/dev/null)
        fi
    fi
    server_ip="$ip"
    echo "$ip"
}

_atomic_modify_json() {
    local file="$1" filter="$2"
    local tmp="${file}.tmp.$$"
    if jq "$filter" "$file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        _error "JSON 修改失败。"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# IP preference helpers
#
# The script supports selecting a preferred IP address family (IPv4 or IPv6)
# when performing network operations such as public IP discovery. The chosen
# preference is persisted in a simple configuration file within the Xray
# configuration directory. If no preference is set, IPv4 is assumed by
# default. These helper functions handle reading and writing this preference
# as well as presenting a user-facing menu for changing it.

# Return the currently configured IP family preference. If the preference
# file does not exist or contains an unexpected value, "ipv4" is returned.
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

# Persist the given IP family preference to disk. Accepts only "ipv4" or
# "ipv6" as valid arguments. Returns 0 on success, 1 on failure.
_set_ip_preference() {
    local pref="$1"
    case "$pref" in
        ipv4|ipv6)
            mkdir -p "$XRAY_DIR" 2>/dev/null || true
            echo "$pref" > "$IP_PREF_FILE" 2>/dev/null || return 1
            # Apply system-wide gai.conf preference and clear cached IP.
            _apply_system_ip_preference "$pref"
            unset server_ip
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


# Modify the system address selection policy according to the given IP preference.
# For IPv4, this function ensures that /etc/gai.conf contains a precedence rule
# preferring IPv4-mapped addresses. For IPv6, it comments out that rule to
# restore the default IPv6 priority. The function creates a backup of the
# original gai.conf on first invocation. See ArchWiki and other references
# explaining that uncommenting or adding the line
# 'precedence ::ffff:0:0/96 100' forces IPv4 preference【484791851435576†L894-L902】,
# while removing or commenting it reverts to IPv6 priority【873299726000284†L50-L58】.
_apply_system_ip_preference() {
    local pref="$1"
    local gai_conf="/etc/gai.conf"
    # Ensure the configuration file exists
    [ -f "$gai_conf" ] || touch "$gai_conf"
    # 取消脚本内的备份文件操作，直接按当前配置原地调整。
    sed -i -e "/^[[:space:]]*precedence[[:space:]]\+::ffff:0:0\/96/ s/^/#/" "$gai_conf"
    if [ "$pref" = "ipv4" ]; then
        # Append the IPv4 precedence rule if it is not already present
        if ! grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' "$gai_conf"; then
            echo 'precedence ::ffff:0:0/96 100' >> "$gai_conf"
        fi
    fi
}

# Interactive menu allowing the user to choose between IPv4- or IPv6-first
# behaviour for public IP detection. Displays the current preference and
# shows the current detected IPv4 and IPv6 public addresses if available.
_choose_ip_preference() {
    local current
    current=$(_get_ip_preference)
    # Detect current IPv4 and IPv6 addresses separately.
    local ip4="" ip6=""
    # Attempt detection using curl
    if command -v curl >/dev/null 2>&1; then
        # IPv4: try multiple services, fall back to api.ipify.org
        ip4=$(curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
               || curl -s4 --max-time 5 ipinfo.io/ip 2>/dev/null \
               || curl -s4 --max-time 5 api.ipify.org 2>/dev/null || true)
        # IPv6: try multiple services, fall back to api6.ipify.org
        ip6=$(curl -s6 --max-time 5 icanhazip.com 2>/dev/null \
               || curl -s6 --max-time 5 ipinfo.io/ip 2>/dev/null \
               || curl -s6 --max-time 5 api6.ipify.org 2>/dev/null || true)
    fi
    # Attempt detection using wget if either is missing
    if command -v wget >/dev/null 2>&1; then
        if [ -z "$ip4" ]; then
            ip4=$(wget -qO- -4 --timeout=5 icanhazip.com 2>/dev/null \
                   || wget -qO- -4 --timeout=5 ipinfo.io/ip 2>/dev/null \
                   || wget -qO- -4 --timeout=5 api.ipify.org 2>/dev/null || true)
        fi
        if [ -z "$ip6" ]; then
            ip6=$(wget -qO- -6 --timeout=5 icanhazip.com 2>/dev/null \
                   || wget -qO- -6 --timeout=5 ipinfo.io/ip 2>/dev/null \
                   || wget -qO- -6 --timeout=5 api6.ipify.org 2>/dev/null || true)
        fi
    fi
    echo ""
    # Display the current preference using proper casing (IPv4/IPv6)
    local display_pref
    if [ "$current" = "ipv6" ]; then
        display_pref="IPv6"
    else
        display_pref="IPv4"
    fi
    echo -e "${CYAN}当前网络优先级设置: ${NC}${GREEN}${display_pref} 优先${NC}"
    echo ""
    # Display detected IP addresses; show '无' if not found
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
            if _set_ip_preference ipv4; then
                _success "已设置 IPv4 优先。"
            else
                _error "设置 IPv4 优先失败。"
            fi
            ;;
        2)
            if _set_ip_preference ipv6; then
                _success "已设置 IPv6 优先。"
            else
                _error "设置 IPv6 优先失败。"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            _error "无效输入。"
            ;;
    esac
    _pause
}





_get_mem_limit() {
    # 取消内存回收/限额机制，交由 Xray/Go 内核自行处理。
    echo 0
    return 0
}


_check_port_occupied() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -q ":${port} " && return 0
        ss -lnu 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -q ":${port} " && return 0
        netstat -lnu 2>/dev/null | grep -q ":${port} " && return 0
    fi
    return 1
}

_check_xray_port_conflict() {
    local port="$1"
    if _check_port_occupied "$port"; then
        _error "端口 ${port} 已被系统占用。"
        return 0
    fi
    if [ -f "$XRAY_CONFIG" ] && jq -e ".inbounds[] | select(.port == $port)" "$XRAY_CONFIG" >/dev/null 2>&1; then
        _error "端口 ${port} 已被 Xray 节点使用。"
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
        _check_xray_port_conflict "$port" && continue
        break
    done
    echo "$port"
}

_init_xray_config() {
    mkdir -p "$XRAY_DIR"
    # 尽量关闭运行时自带的高噪声输出，保持脚本和服务侧低日志占用。
    # 1) Xray 配置默认使用 warning 级别；
    # 2) systemd/openrc 服务不额外落地运行日志；
    # 3) 若需排障，可临时调高 loglevel 或手动查看 systemd journal。
    touch "$XRAY_LOG" 2>/dev/null || true
    if [ ! -s "$XRAY_CONFIG" ]; then
        cat > "$XRAY_CONFIG" <<'JSON'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": []
  }
}
JSON
        _success "Xray 配置文件已初始化。"
    fi
    [ -s "$XRAY_METADATA" ] || echo '{}' > "$XRAY_METADATA"
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
# 不保存运行日志，保持最小 IO 占用。如果需要查看日志，可使用 systemd/journal 或在配置中调整 loglevel。
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
        openrc)  _create_xray_openrc_service ;;
        *) _warn "未检测到 systemd/openrc，请手动管理 Xray 进程。" ;;
    esac
}

_manage_xray_service() {
    local action="$1"
    case "$INIT_SYSTEM" in
        systemd)
            if [ "$action" = "status" ]; then
                if systemctl is-active --quiet xray >/dev/null 2>&1; then
                    _success "Xray 服务运行中。"
                else
                    _warn "Xray 服务已停止。"
                fi
                return
            fi
            if systemctl "$action" xray >/dev/null 2>&1; then
                case "$action" in
                    start) _success "Xray 服务已启动。" ;;
                    stop) _success "Xray 服务已停止。" ;;
                    restart) _success "Xray 服务已重启。" ;;
                esac
            else
                _error "Xray 服务${action}失败。"
                return 1
            fi
            ;;
        openrc)
            if [ "$action" = "status" ]; then
                if rc-service xray status >/dev/null 2>&1; then
                    _success "Xray 服务运行中。"
                else
                    _warn "Xray 服务已停止。"
                fi
                return
            fi
            if rc-service xray "$action" >/dev/null 2>&1; then
                case "$action" in
                    start) _success "Xray 服务已启动。" ;;
                    stop) _success "Xray 服务已停止。" ;;
                    restart) _success "Xray 服务已重启。" ;;
                esac
            else
                _error "Xray 服务${action}失败。"
                return 1
            fi
            ;;
        *)
            _warn "未检测到服务管理器，跳过 ${action}。"
            ;;
    esac
}
_install_or_update_xray() {
    local is_first_install=false
    [ ! -f "$XRAY_BIN" ] && is_first_install=true

    if [ "$is_first_install" = true ]; then
        _info "Xray 核心未安装，正在执行首次安装..."
    else
        local current_ver
        current_ver=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
        _info "当前 Xray 版本: v${current_ver}，正在检查更新..."
    fi

    command -v unzip >/dev/null 2>&1 || _pkg_install unzip

    local arch=$(uname -m)
    local xray_arch="64"
    case "$arch" in
        x86_64|amd64)  xray_arch="64" ;;
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        armv7l)        xray_arch="arm32-v7a" ;;
    esac

    local download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local tmp_zip="${tmp_dir}/xray.zip"

    _info "下载地址: ${download_url}"
    if command -v curl >/dev/null 2>&1; then
        curl -LfsS "$download_url" -o "$tmp_zip" || { _error "Xray 下载失败。"; rm -rf "$tmp_dir"; return 1; }
    else
        wget -qO "$tmp_zip" "$download_url" || { _error "Xray 下载失败。"; rm -rf "$tmp_dir"; return 1; }
    fi

    unzip -qo "$tmp_zip" -d "$tmp_dir" || { _error "Xray 解压失败。"; rm -rf "$tmp_dir"; return 1; }

    mv "${tmp_dir}/xray" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    mkdir -p "$XRAY_DIR"
    [ -f "${tmp_dir}/geoip.dat" ] && mv "${tmp_dir}/geoip.dat" "$XRAY_DIR/"
    [ -f "${tmp_dir}/geosite.dat" ] && mv "${tmp_dir}/geosite.dat" "$XRAY_DIR/"
    rm -rf "$tmp_dir"

    local version
    version=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
    _success "Xray-core v${version} 安装/更新成功。"

    if [ "$is_first_install" = true ]; then
        _info "首次安装 Xray，正在初始化配置与服务..."
        _init_xray_config
        # Default to IPv4 priority on first installation; ignore errors.
        _set_ip_preference ipv4 >/dev/null 2>&1 || true
        _create_xray_service
        _manage_xray_service start
        _success "Xray 首次安装完成并已启动。"
    else
        _init_xray_config
        _create_xray_service
        _manage_xray_service restart
    fi
}

_view_xray_log() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        journalctl -u xray -n 50 --no-pager -f
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        # 在 openrc 模式下，我们默认不持久保存日志（见 _create_xray_openrc_service），因此没有文件可供查看。
        # 如果用户需要查看日志，可以通过修改配置中的 loglevel 并手动重定向输出。
        _warn "当前 openrc 服务未保存日志。如需查看日志，请调整服务脚本或使用其他方式获取输出。"
    else
        _warn "未检测到日志管理器。"
    fi
}

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

_save_xray_meta() {
    local tag="$1" name="$2" link="$3"
    shift 3
    local tmp="${XRAY_METADATA}.tmp.$$"
    jq --arg t "$tag" --arg n "$name" --arg l "$link" '. + {($t): {name: $n, share_link: $l}}' "$XRAY_METADATA" > "$tmp" 2>/dev/null && mv "$tmp" "$XRAY_METADATA" || { rm -f "$tmp"; return 1; }
    for pair in "$@"; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        [ -n "$key" ] && [ -n "$val" ] || continue
        local tmp2="${XRAY_METADATA}.tmp.$$"
        jq --arg t "$tag" --arg k "$key" --arg v "$val" '.[$t][$k] = $v' "$XRAY_METADATA" > "$tmp2" 2>/dev/null && mv "$tmp2" "$XRAY_METADATA" || rm -f "$tmp2"
    done
}

_add_ss2022_reality() {
    [ ! -f "$XRAY_BIN" ] && { _error "请先安装/更新 Xray 核心。"; return 1; }
    [ -z "$server_ip" ] && server_ip=$(_get_public_ip)
    local node_ip="$server_ip"

    if [ -n "$server_ip" ]; then
        read -p "请输入服务器 IP (回车默认当前检测 IP: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
    else
        _warn "未能自动检测到当前公网 IP，请手动输入。"
        read -p "请输入服务器 IP: " node_ip
    fi

    local port
    port=$(_input_port)

    local sni="$DEFAULT_SNI"
    read -p "请输入伪装域名 SNI (默认: ${DEFAULT_SNI}): " custom_sni
    sni=${custom_sni:-$DEFAULT_SNI}

    local default_name="SS2022-REALITY-${port}"
    read -p "请输入节点名称 (默认: ${default_name}): " custom_name
    local name=${custom_name:-$default_name}

    local method="2022-blake3-aes-128-gcm"
    local password
    password=$(openssl rand -base64 16)
    _generate_reality_keys || return 1

    local tag="xray-ss2022-reality-${port}"
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local stream
    stream=$(_build_reality_stream "raw" "$sni" "$REALITY_PRIVATE_KEY" "$REALITY_SHORT_ID")
    local inbound
    inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg method "$method" --arg password "$password" --argjson stream "$stream" '
        {
            "tag": $tag,
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "shadowsocks",
            "settings": {
                "method": $method,
                "password": $password,
                "network": "tcp,udp"
            },
            "streamSettings": $stream
        }')

    _atomic_modify_json "$XRAY_CONFIG" ".inbounds += [$inbound]" || return 1

    local qx_link="shadowsocks=${link_ip}:${port}, method=${method}, password=${password}, obfs=over-tls, obfs-host=${sni}, tls-verification=true, reality-base64-pubkey=${REALITY_PUBLIC_KEY}, reality-hex-shortid=${REALITY_SHORT_ID}, udp-relay=true, udp-over-tcp=sp.v2, tag=${name}"

    _save_xray_meta "$tag" "$name" "$qx_link" \
        "publicKey=${REALITY_PUBLIC_KEY}" \
        "shortId=${REALITY_SHORT_ID}" \
        "server=${node_ip}" \
        "sni=${sni}" \
        "method=${method}"

    _manage_xray_service restart
    _success "SS2022+Reality 节点 [${name}] 添加成功。"
    echo ""
    echo -e "  ${YELLOW}Quantumult X:${NC} ${qx_link}"
    echo ""
}

_view_xray_nodes() {
    if [ ! -f "$XRAY_CONFIG" ] || ! jq -e '.inbounds | length > 0' "$XRAY_CONFIG" >/dev/null 2>&1; then
        _warn "当前没有 Xray 节点。"
        return
    fi
    echo ""
    echo -e "${YELLOW}══════════════════ Xray 节点列表 ══════════════════${NC}"
    local count=0
    local -a tags
    mapfile -t tags < <(jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null)
    for tag in "${tags[@]}"; do
        count=$((count + 1))
        local port protocol name security network link
        protocol=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .protocol" "$XRAY_CONFIG")
        port=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .port" "$XRAY_CONFIG")
        network=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .streamSettings.network // \"raw\"" "$XRAY_CONFIG")
        security=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .streamSettings.security // \"none\"" "$XRAY_CONFIG")
        name=$(jq -r ".\"$tag\".name // \"$tag\"" "$XRAY_METADATA" 2>/dev/null)
        link=$(jq -r ".\"$tag\".share_link // empty" "$XRAY_METADATA" 2>/dev/null)
        echo ""
        echo -e "  ${GREEN}[${count}]${NC} ${CYAN}${name}${NC}"
        echo -e "      协议: ${YELLOW}${protocol}+${security}+${network}${NC}  |  端口: ${GREEN}${port}${NC}  |  标签: ${CYAN}${tag}${NC}"
        [ -n "$link" ] && echo -e "      ${YELLOW}Quantumult X:${NC} ${link}"
    done
}

_delete_xray_node() {
    if [ ! -f "$XRAY_CONFIG" ] || ! jq -e '.inbounds | length > 0' "$XRAY_CONFIG" >/dev/null 2>&1; then
        _warn "当前没有 Xray 节点。"
        return
    fi
    local tags
    tags=$(jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null)
    echo ""
    echo -e "${YELLOW}══════════ 选择要删除的节点 ══════════${NC}"
    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local port name
        port=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .port" "$XRAY_CONFIG")
        name=$(jq -r ".\"$tag\".name // \"$tag\"" "$XRAY_METADATA" 2>/dev/null)
        echo -e "  ${GREEN}[$((i+1))]${NC} ${name} (端口: ${port})"
    done
    echo -e "  ${RED}[0]${NC} 返回"
    echo ""
    read -p "请选择 [0-${#tags[@]}]: " choice
    [ "$choice" = "0" ] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tags[@]}" ]; then
        _error "无效选择。"
        return
    fi
    local target_tag="${tags[$((choice-1))]}"
    local target_name
    target_name=$(jq -r ".\"$target_tag\".name // \"$target_tag\"" "$XRAY_METADATA" 2>/dev/null)
    read -p "确定删除 [${target_name}]? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { _info "已取消。"; return; }
    _atomic_modify_json "$XRAY_CONFIG" "del(.inbounds[] | select(.tag == \"$target_tag\"))" || return 1
    _atomic_modify_json "$XRAY_METADATA" "del(.\"$target_tag\")" >/dev/null 2>&1 || true
    _manage_xray_service restart
    _success "节点 [${target_name}] 已删除。"
}

_modify_xray_port() {
    if [ ! -f "$XRAY_CONFIG" ] || ! jq -e '.inbounds | length > 0' "$XRAY_CONFIG" >/dev/null 2>&1; then
        _warn "当前没有 Xray 节点。"
        return
    fi
    local tags
    tags=$(jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null)
    echo ""
    echo -e "${YELLOW}══════════ 选择要修改端口的节点 ══════════${NC}"
    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local port name
        port=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .port" "$XRAY_CONFIG")
        name=$(jq -r ".\"$tag\".name // \"$tag\"" "$XRAY_METADATA" 2>/dev/null)
        echo -e "  ${GREEN}[$((i+1))]${NC} ${name} (端口: ${port})"
    done
    echo -e "  ${RED}[0]${NC} 返回"
    echo ""
    read -p "请选择 [0-${#tags[@]}]: " choice
    [ "$choice" = "0" ] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tags[@]}" ]; then
        _error "无效选择。"
        return
    fi
    local target_tag="${tags[$((choice-1))]}"
    local old_port target_name
    old_port=$(jq -r ".inbounds[] | select(.tag == \"$target_tag\") | .port" "$XRAY_CONFIG")
    target_name=$(jq -r ".\"$target_tag\".name // \"$target_tag\"" "$XRAY_METADATA" 2>/dev/null)
    _info "当前端口: ${old_port}"
    local new_port
    new_port=$(_input_port)
    local new_tag new_name
    new_tag=$(echo "$target_tag" | sed "s/${old_port}/${new_port}/g")
    new_name=$(echo "$target_name" | sed "s/${old_port}/${new_port}/g")
    _atomic_modify_json "$XRAY_CONFIG" "(.inbounds[] | select(.tag == \"$target_tag\") | .port) = $new_port" || return 1
    _atomic_modify_json "$XRAY_CONFIG" "(.inbounds[] | select(.tag == \"$target_tag\") | .tag) = \"$new_tag\"" || return 1
    local old_link new_link
    old_link=$(jq -r ".\"$target_tag\".share_link // empty" "$XRAY_METADATA" 2>/dev/null)
    new_link=$(echo "$old_link" | sed "s/:${old_port}/:${new_port}/g; s/-${old_port}/-${new_port}/g")
    local tmp="${XRAY_METADATA}.tmp.$$"
    jq --arg ot "$target_tag" --arg nt "$new_tag" --arg n "$new_name" --arg l "$new_link" '. + {($nt): (.[$ot] + {name: $n, share_link: $l})} | del(.[$ot])' "$XRAY_METADATA" > "$tmp" 2>/dev/null && mv "$tmp" "$XRAY_METADATA" || rm -f "$tmp"
    _manage_xray_service restart
    _success "节点 [${new_name}] 端口已改为 ${new_port}。"
}

_remove_xray_runtime() {
    _manage_xray_service stop >/dev/null 2>&1 || true
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl disable xray >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-service xray stop >/dev/null 2>&1 || true
        rc-update del xray default >/dev/null 2>&1 || true
        rm -f /etc/init.d/xray
    fi
    rm -f "$XRAY_BIN" "$XRAY_LOG" "$XRAY_PID_FILE"
    rm -rf "$XRAY_DIR"
}

_uninstall_xray() {
    echo ""
    _warn "即将卸载 Xray 核心及其全部配置，保留管理脚本。"
    read -p "确定要卸载吗? (输入 yes 确认): " confirm
    [ "$confirm" = "yes" ] || { _info "卸载已取消。"; return; }
    _remove_xray_runtime
    _success "Xray 已完全卸载，管理脚本仍可继续使用。"
}

_uninstall_script() {
    _warn "！！！警告！！！"
    _warn "本操作将停止并禁用 Xray 服务，"
    _warn "删除所有相关文件（包括二进制、配置文件、快捷命令及脚本本体）。"

    echo ""
    echo "即将删除以下内容："
    echo -e "  ${RED}-${NC} Xray 配置目录: ${XRAY_DIR}"
    echo -e "  ${RED}-${NC} Xray 二进制: ${XRAY_BIN}"
    echo -e "  ${RED}-${NC} 系统快捷命令: ${SCRIPT_INSTALL_PATH}"
    [ "$SCRIPT_ALIAS_PATH" != "$SCRIPT_INSTALL_PATH" ] && echo -e "  ${RED}-${NC} 系统快捷命令: ${SCRIPT_ALIAS_PATH}"
    [ -n "$SELF_SCRIPT_PATH" ] && [ -f "$SELF_SCRIPT_PATH" ] && echo -e "  ${RED}-${NC} 管理脚本: ${SELF_SCRIPT_PATH}"
    echo ""

    read -p "$(echo -e ${YELLOW}"确定要执行卸载吗? (y/N): "${NC})" confirm_main "$@"
    [[ "$confirm_main" != "y" && "$confirm_main" != "Y" ]] && _info "卸载已取消。" && return

    _info "正在停止并清理 Xray ..."
    _remove_xray_runtime

    _info "正在清理快捷命令与脚本本体..."
    rm -f "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH"
    if [ -n "$SELF_SCRIPT_PATH" ] && [ -f "$SELF_SCRIPT_PATH" ] && [ "$SELF_SCRIPT_PATH" != "$SCRIPT_INSTALL_PATH" ]; then
        rm -f "$SELF_SCRIPT_PATH"
    fi

    _success "清理完成。脚本已自毁。再见！"
    [ -n "$SELF_SCRIPT_PATH" ] && [ -f "$SELF_SCRIPT_PATH" ] && rm -f "$SELF_SCRIPT_PATH"
    exit 0
}

_show_status_header() {
    local xray_status="${RED}未安装${NC}"
    local xray_ver=""
    if [ -f "$XRAY_BIN" ]; then
        xray_ver=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            systemctl is-active xray >/dev/null 2>&1 && xray_status="${GREEN}● 运行中${NC}" || xray_status="${YELLOW}○ 已停止${NC}"
        elif [ "$INIT_SYSTEM" = "openrc" ]; then
            rc-service xray status >/dev/null 2>&1 && xray_status="${GREEN}● 运行中${NC}" || xray_status="${YELLOW}○ 已停止${NC}"
        else
            xray_status="${YELLOW}○ 未知${NC}"
        fi
    fi
    local node_count
    node_count=$(jq '.inbounds | length' "$XRAY_CONFIG" 2>/dev/null || echo 0)
    echo -e "=================================================="
    echo -e " Xray 独立脚本 v${SCRIPT_VERSION}"
    echo -e " 单协议: SS2022 + Reality"
    echo -e "=================================================="
    if [ -n "$xray_ver" ]; then
        echo -e " Xray v${xray_ver}: ${xray_status} (${node_count}节点)"
    else
        echo -e " Xray: ${xray_status} (${node_count}节点)"
    fi
    echo -e "--------------------------------------------------"
}

_xray_menu() {
    while true; do
        clear
        echo ""
        _show_status_header
        echo -e " ${CYAN}【服务控制】${NC}"
        _menu_item 1  "安装/更新 Xray 内核"
        _menu_item 2  "启动 Xray"
        _menu_item 3  "停止 Xray"
        _menu_item 4  "重启 Xray"
        _menu_item 5  "查看 Xray 状态"
        _menu_item 6  "查看 Xray 日志"
        echo ""
        echo -e " ${CYAN}【节点管理】${NC}"
        _menu_item 7  "添加 SS2022+Reality 节点"
        _menu_item 8  "查看所有节点"
        _menu_item 9  "删除节点"
        _menu_item 10 "修改节点端口"
        _menu_item 11 "更新脚本"
        _menu_item 12 "设置网络优先级 (IPv4/IPv6)"
        # 已移除 BBR 优化功能
        echo ""
        _menu_danger 88 "卸载 Xray"
        _menu_danger 99 "卸载脚本"
        _menu_exit 0 "退出脚本"
        echo -e "=================================================="
        read -p "请选择 [0-99]: " choice
        case "$choice" in
            1) _install_or_update_xray; _pause ;;
            2) [ -f "$XRAY_BIN" ] && _manage_xray_service start; _pause ;;
            3) [ -f "$XRAY_BIN" ] && _manage_xray_service stop; _pause ;;
            4) [ -f "$XRAY_BIN" ] && _manage_xray_service restart; _pause ;;
            5) [ -f "$XRAY_BIN" ] && _manage_xray_service status; _pause ;;
            6) [ -f "$XRAY_BIN" ] && _view_xray_log ;;
            7) _init_xray_config; _add_ss2022_reality; _pause ;;
            8) _view_xray_nodes; _pause ;;
            9) _delete_xray_node; _pause ;;
            10) _modify_xray_port; _pause ;;
            11) _update_script_self; _pause; exit 0 ;;
            12) _choose_ip_preference ;;
            88) _uninstall_xray; _pause ;;
            99) _uninstall_script ;;
            0) exit 0 ;;
            *) _error "无效输入。"; _pause ;;
        esac
    done
}

_maybe_handle_internal_subcommand() {
    # Memory tuning subcommand has been removed. No internal subcommands to handle.
    return 0
}

_main() {
    # 已移除内部子命令处理逻辑，直接执行后续步骤
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
