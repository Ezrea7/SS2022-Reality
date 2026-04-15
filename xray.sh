#!/bin/bash

# ============================================================
#      Xray SS2022 + Reality 独立安装管理脚本 (单协议版)
# ============================================================

SCRIPT_VERSION="0.0.4"
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

    _success "脚本已更新。当前快捷命令: ${SCRIPT_CMD_NAME} / ${SCRIPT_CMD_ALIAS}"
    _warn "请重新运行 ${SCRIPT_CMD_NAME} 或 ${SCRIPT_CMD_ALIAS} 以加载新版本。"
}

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
        1) _set_ip_preference ipv4 && _success "已设置 IPv4 优先。" || _error "设置 IPv4 优先失败。" ;;
        2) _set_ip_preference ipv6 && _success "已设置 IPv6 优先。" || _error "设置 IPv6 优先失败。" ;;
        0) return 0 ;;
        *) _error "无效输入。" ;;
    esac
    _pause
}

_init_server_ip() {
    _info "正在获取服务器公网 IP..."
    server_ip=$(_get_public_ip)
    if [ -z "$server_ip" ] || [ "$server_ip" = "null" ]; then
        _warn "自动获取 IP 失败，请添加节点时手动输入。"
        server_ip=""
    else
        _success "当前服务器公网 IP: ${server_ip}"
    fi
}

_get_mem_limit() {
    local total_mem_mb limit
    total_mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    if ! [[ "$total_mem_mb" =~ ^[0-9]+$ ]] || [ "$total_mem_mb" -le 0 ]; then
        echo 256
        return 0
    fi
    limit=$((total_mem_mb * 90 / 100))
    [ "$limit" -lt 10 ] && limit=10
    echo "$limit"
}

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

_input_port() {
    local port=""
    while true; do
        read -p "请输入监听端口: " port
        [[ -z "$port" ]] && _error "端口不能为空。" && continue
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            _error "无效端口号。"
            continue
        fi
        echo "$port"
        return 0
    done
}

_init_xray_config() {
    mkdir -p "$XRAY_DIR"
    touch "$XRAY_LOG" 2>/dev/null || true

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
        _success "Xray 配置文件已初始化。"
    fi

    [ -s "$XRAY_METADATA" ] || echo '{}' > "$XRAY_METADATA"
}

_create_xray_systemd_service() {
    local mem_limit_mb
    mem_limit_mb=$(_get_mem_limit)
    cat > /etc/systemd/system/xray.service <<EOF2
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
Environment="GOMEMLIMIT=${mem_limit_mb}MiB"
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
    local mem_limit_mb
    mem_limit_mb=$(_get_mem_limit)
    cat > /etc/init.d/xray <<EOF2
#!/sbin/openrc-run
description="Xray Service"
command="${XRAY_BIN}"
command_args="run -c ${XRAY_CONFIG}"
supervisor="supervise-daemon"
supervise_daemon_args="--env GOMEMLIMIT=${mem_limit_mb}MiB"
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
    echo -e " Xray ${YELLOW}$(_get_xray_core_version)${NC}: ${GREEN}$(_get_xray_service_status)${NC} ($(_get_xray_node_count)节点)"
    echo -e "--------------------------------------------------"
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
        start) _success "Xray 服务已启动。" ;;
        stop) _success "Xray 服务已停止。" ;;
        restart) _success "Xray 服务已重启。" ;;
    esac
}

_install_or_update_xray() {
    local is_first_install=false current_ver arch xray_arch download_url dgst_url tmp_dir tmp_zip version dgst_content expected_hash actual_hash
    [ ! -f "$XRAY_BIN" ] && is_first_install=true

    if [ "$is_first_install" = true ]; then
        _info "Xray 核心未安装，正在执行首次安装..."
    else
        current_ver=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
        _info "当前 Xray 版本: v${current_ver}，正在检查更新..."
    fi

    command -v unzip >/dev/null 2>&1 || _pkg_install unzip
    command -v sha256sum >/dev/null 2>&1 || _pkg_install coreutils

    arch=$(uname -m)
    xray_arch="64"
    case "$arch" in
        x86_64|amd64) xray_arch="64" ;;
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        armv7l) xray_arch="arm32-v7a" ;;
    esac

    download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip"
    dgst_url="${download_url}.dgst"
    tmp_dir=$(mktemp -d)
    tmp_zip="${tmp_dir}/xray.zip"

    _info "下载地址: ${download_url}"
    _download_to "$download_url" "$tmp_zip" || {
        _error "Xray 下载失败。"
        rm -rf "$tmp_dir"
        return 1
    }

    dgst_content=$(_download_to "$dgst_url" "${tmp_dir}/xray.zip.dgst" >/dev/null 2>&1 && cat "${tmp_dir}/xray.zip.dgst" 2>/dev/null)
    if [ -n "$dgst_content" ] && command -v sha256sum >/dev/null 2>&1; then
        _info "正在进行 SHA256 完整性校验..."
        expected_hash=$(printf '%s\n' "$dgst_content" | grep "SHA2-256" | head -1 | awk -F'= ' '{print $2}' | tr -d '[:space:]')
        if [ -n "$expected_hash" ]; then
            actual_hash=$(sha256sum "$tmp_zip" | awk '{print $1}')
            if [ "$(printf '%s' "$expected_hash" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$actual_hash" | tr 'A-Z' 'a-z')" ]; then
                _error "SHA256 校验失败，已取消安装。"
                rm -rf "$tmp_dir"
                return 1
            fi
            _success "SHA256 校验通过。"
        else
            _warn "校验文件格式异常，跳过校验。"
        fi
    else
        _warn "未获取到校验文件，跳过 SHA256 校验。"
    fi

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
    _success "Xray-core v${version} 安装/更新成功。"

    _init_xray_config
    _create_xray_service

    if [ "$is_first_install" = true ]; then
        _info "首次安装 Xray，正在初始化配置与服务..."
        _set_ip_preference ipv4 >/dev/null 2>&1 || true
        _manage_xray_service start
        _success "Xray 首次安装完成并已启动。"
    else
        _manage_xray_service restart
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

_get_inbound_field() {
    local tag="$1" field="$2"
    jq --arg tag "$tag" -r ".inbounds[] | select(.tag == \$tag) | ${field} // empty" "$XRAY_CONFIG" 2>/dev/null
}

_get_xray_meta_field() {
    local tag="$1" field="$2"
    jq --arg tag "$tag" --arg field "$field" -r '.[$tag][$field] // empty' "$XRAY_METADATA" 2>/dev/null
}

_get_xray_tag_name() {
    local tag="$1" name
    name=$(_get_xray_meta_field "$tag" name)
    [ -n "$name" ] && printf '%s\n' "$name" || printf '%s\n' "$tag"
}

_get_xray_qx_link() {
    local tag="$1" saved_link built_link
    saved_link=$(_get_xray_meta_field "$tag" qx_link)
    [ -n "$saved_link" ] && { echo "$saved_link"; return 0; }
    built_link=$(_build_qx_link "$tag" 2>/dev/null)
    [ -n "$built_link" ] && { echo "$built_link"; return 0; }
    return 1
}

_show_xray_qx_link() {
    local tag="$1" title="${2:-Quantumult X}" link
    link=$(_get_xray_qx_link "$tag")
    [ -n "$link" ] || { _warn "未能生成分享链接。"; return 1; }
    echo ""
    echo -e "  ${YELLOW}${title}:${NC} ${link}"
    echo ""
}

_list_xray_tags() {
    jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null
}

_delete_xray_inbound_by_tag() {
    local tag="$1"
    _atomic_modify_json "$XRAY_CONFIG" "del(.inbounds[] | select(.tag == \"$tag\"))" || {
        _error "删除节点配置失败。"
        return 1
    }
}

_update_xray_inbound_port_and_tag() {
    local tag="$1" new_port="$2" new_tag="$3"
    _atomic_modify_json "$XRAY_CONFIG" "(.inbounds[] | select(.tag == \"$tag\") | .port) = $new_port | (.inbounds[] | select(.tag == \"$tag\") | .tag) = \"$new_tag\"" || {
        _error "更新节点端口失败。"
        return 1
    }
}

_replace_port_in_text() {
    local text="$1" old_port="$2" new_port="$3"
    printf '%s' "$text" | sed "s/:${old_port}/:${new_port}/g; s/-${old_port}/-${new_port}/g"
}

_set_xray_meta_field() {
    local tag="$1" key="$2" value="$3"
    _atomic_modify_json "$XRAY_METADATA" ".\"$tag\".\"$key\" = \"$value\"" >/dev/null 2>&1
}

_save_xray_meta() {
    local tag="$1" name="$2" link="$3"
    shift 3

    _atomic_modify_json "$XRAY_METADATA" ". + {\"$tag\": {name: \"$name\", qx_link: \"$link\"}}" || return 1

    for pair in "$@"; do
        local key="${pair%%=*}" val="${pair#*=}"
        [ -n "$key" ] && [ -n "$val" ] || continue
        _set_xray_meta_field "$tag" "$key" "$val" || true
    done
}

_build_qx_link() {
    local tag="$1"
    local port name method password sni public_key short_id server_ip link_ip

    port=$(_get_inbound_field "$tag" '.port')
    [ -n "$port" ] || return 1

    name=$(_get_xray_tag_name "$tag")
    method=$(_get_xray_meta_field "$tag" method)
    password=$(_get_xray_meta_field "$tag" password)
    sni=$(_get_xray_meta_field "$tag" sni)
    public_key=$(_get_xray_meta_field "$tag" publicKey)
    short_id=$(_get_xray_meta_field "$tag" shortId)
    server_ip=$(_get_xray_meta_field "$tag" server)

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
_has_xray_nodes() {
    [ -f "$XRAY_CONFIG" ] && jq -e '.inbounds | length > 0' "$XRAY_CONFIG" >/dev/null 2>&1
}

_select_xray_tag() {
    local prompt="$1" choice i=1
    local -a tags
    mapfile -t tags < <(_list_xray_tags)
    [ "${#tags[@]}" -gt 0 ] || return 1

    echo "" >&2
    echo -e "${YELLOW}${prompt}${NC}" >&2
    for tag in "${tags[@]}"; do
        echo -e "  ${GREEN}[${i}]${NC} $(_get_xray_tag_name "$tag") (端口: $(_get_inbound_field "$tag" '.port'))" >&2
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

_add_ss2022_reality() {
    [ -z "$server_ip" ] && _init_server_ip

    local node_ip custom_ip port sni custom_sni default_name custom_name name tag method password link_ip stream inbound qx_link
    node_ip="$server_ip"

    if [ -n "$server_ip" ]; then
        read -p "请输入服务器 IP (回车默认当前检测 IP: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
    else
        _warn "未能自动检测到当前公网 IP，请手动输入。"
        read -p "请输入服务器 IP: " node_ip
    fi

    port=$(_input_port)
    sni="$DEFAULT_SNI"
    read -p "请输入伪装域名 SNI (默认: ${DEFAULT_SNI}): " custom_sni
    sni=${custom_sni:-$DEFAULT_SNI}

    default_name="SS2022-REALITY-${port}"
    while true; do
        read -p "请输入节点名称 (默认: ${default_name}): " custom_name
        name=${custom_name:-$default_name}
        tag="$name"
        if jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "$XRAY_CONFIG" >/dev/null 2>&1; then
            _error "节点名称已存在，请重新输入。"
            continue
        fi
        break
    done

    method="2022-blake3-aes-128-gcm"
    password=$(openssl rand -base64 16)
    _generate_reality_keys || return 1

    tag="$name"
    link_ip="$node_ip"
    [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    stream=$(_build_reality_stream "raw" "$sni" "$REALITY_PRIVATE_KEY" "$REALITY_SHORT_ID")
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

    qx_link="shadowsocks=${link_ip}:${port}, method=${method}, password=${password}, obfs=over-tls, obfs-host=${sni}, tls-verification=true, reality-base64-pubkey=${REALITY_PUBLIC_KEY}, reality-hex-shortid=${REALITY_SHORT_ID}, udp-relay=true, tag=${name}"

    _save_xray_meta "$tag" "$name" "$qx_link" \
        "password=${password}" \
        "publicKey=${REALITY_PUBLIC_KEY}" \
        "shortId=${REALITY_SHORT_ID}" \
        "server=${node_ip}" \
        "sni=${sni}" \
        "method=${method}"

    _manage_xray_service restart
    _success "SS2022+Reality 节点 [${name}] 添加成功。"
    _show_xray_qx_link "$tag"
}

_view_xray_nodes() {
    if ! _has_xray_nodes; then
        _warn "当前没有 Xray 节点。"
        return
    fi

    echo ""
    echo -e "${YELLOW}══════════════════ Xray 节点列表 ══════════════════${NC}"
    local count=0 tag protocol port network security name link
    while IFS= read -r tag; do
        count=$((count + 1))
        protocol=$(_get_inbound_field "$tag" '.protocol')
        port=$(_get_inbound_field "$tag" '.port')
        network=$(_get_inbound_field "$tag" '.streamSettings.network // "raw"')
        security=$(_get_inbound_field "$tag" '.streamSettings.security // "none"')
        name=$(_get_xray_tag_name "$tag")
        link=$(_get_xray_qx_link "$tag")
        echo ""
        echo -e "  ${GREEN}[${count}]${NC} ${CYAN}${name}${NC}"
        echo -e "      协议: ${YELLOW}${protocol}+${security}+${network}${NC}  |  端口: ${GREEN}${port}${NC}  |  标签: ${CYAN}${tag}${NC}"
        if [ -n "$link" ]; then
            echo -e "      ${YELLOW}Quantumult X:${NC} ${link}"
        else
            echo -e "      ${RED}Quantumult X: 无法生成链接${NC}"
        fi
    done < <(_list_xray_tags)
}

_delete_xray_node() {
    if ! _has_xray_nodes; then
        _warn "当前没有 Xray 节点。"
        return
    fi

    local target_tag target_name confirm
    target_tag=$(_select_xray_tag "══════════ 选择要删除的节点 ══════════") || return
    target_name=$(_get_xray_tag_name "$target_tag")
    read -p "确定删除 [${target_name}]? (y/N): " confirm
    _confirm_yes "$confirm" || { _info "已取消。"; return; }

    _delete_xray_inbound_by_tag "$target_tag" || return 1
    _atomic_modify_json "$XRAY_METADATA" "del(.\"$target_tag\")" >/dev/null 2>&1 || true
    _manage_xray_service restart
    _success "节点 [${target_name}] 已删除。"
}

_modify_xray_port() {
    if ! _has_xray_nodes; then
        _warn "当前没有 Xray 节点。"
        return
    fi

    local target_tag old_port target_name new_port new_tag new_name old_qx_link new_link tmp
    target_tag=$(_select_xray_tag "══════════ 选择要修改端口的节点 ══════════") || return
    old_port=$(_get_inbound_field "$target_tag" '.port')
    target_name=$(_get_xray_tag_name "$target_tag")

    [ -n "$old_port" ] && [ "$old_port" != "null" ] || { _error "未找到目标节点端口。"; return 1; }

    _info "当前端口: ${old_port}"
    new_port=$(_input_port)
    [ "$new_port" = "$old_port" ] && { _info "新端口与当前端口一致，无需修改。"; return 0; }

    new_tag=$(printf '%s' "$target_tag" | sed "s/${old_port}/${new_port}/g")
    new_name=$(printf '%s' "$target_name" | sed "s/${old_port}/${new_port}/g")
    [ -n "$new_tag" ] || new_tag="$target_tag"
    [ -n "$new_name" ] || new_name="$target_name"

    if [ "$new_tag" != "$target_tag" ] && jq -e --arg tag "$new_tag" '.inbounds[] | select(.tag == $tag)' "$XRAY_CONFIG" >/dev/null 2>&1; then
        _error "修改后的节点标签已存在，请调整节点名称后再试。"
        return 1
    fi

    old_qx_link=$(_get_xray_qx_link "$target_tag")
    _update_xray_inbound_port_and_tag "$target_tag" "$new_port" "$new_tag" || return 1

    new_link=$(_replace_port_in_text "$old_qx_link" "$old_port" "$new_port")
    [ -n "$new_link" ] || new_link=$(_build_qx_link "$new_tag" 2>/dev/null)
    tmp="${XRAY_METADATA}.tmp.$$"
    jq --arg ot "$target_tag" --arg nt "$new_tag" --arg n "$new_name" --arg l "$new_link" '. + {($nt): ((.[$ot] // {}) + {name: $n, qx_link: $l})} | del(.[$ot])' "$XRAY_METADATA" > "$tmp" 2>/dev/null && mv "$tmp" "$XRAY_METADATA" || {
        rm -f "$tmp"
        _error "更新节点元数据失败。"
        return 1
    }

    _manage_xray_service restart
    _success "节点 [${new_name}] 端口已改为 ${new_port}。"
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

    rm -f "$XRAY_BIN" "$XRAY_LOG" "$XRAY_PID_FILE"
    rm -rf "$XRAY_DIR"
}

_uninstall_xray() {
    echo ""
    _warn "即将卸载 Xray 核心及其所有配置！"
    printf "${YELLOW}确定要卸载吗? (y/N): ${NC}"
    read -r confirm
    _confirm_yes "$confirm" || { _info "卸载已取消。"; return; }

    _cleanup_xray_files
    _success "Xray 核心已完全卸载！"
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

    printf "${YELLOW}确定要执行卸载吗? (y/N): ${NC}"
    read -r confirm_main
    _confirm_yes "$confirm_main" || { _info "卸载已取消。"; return; }

    _cleanup_xray_files

    _info "正在清理快捷命令与脚本本体..."
    rm -f "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH"
    if [ -n "$SELF_SCRIPT_PATH" ] && [ -f "$SELF_SCRIPT_PATH" ] && [ "$SELF_SCRIPT_PATH" != "$SCRIPT_INSTALL_PATH" ]; then
        rm -f "$SELF_SCRIPT_PATH"
    fi

    _success "清理完成。脚本已自毁。再见！"
    [ -n "$SELF_SCRIPT_PATH" ] && [ -f "$SELF_SCRIPT_PATH" ] && rm -f "$SELF_SCRIPT_PATH"
    exit 0
}

_xray_menu() {
    while true; do
        clear
        echo ""
        echo -e "=================================================="
        echo -e " Xray 独立脚本 v${SCRIPT_VERSION}"
        echo -e " 单协议: SS2022 + Reality"
        _show_xray_runtime_summary
        echo -e "=================================================="
        echo -e " ${CYAN}【服务控制】${NC}"
        _menu_item 1  "安装/更新 Xray 内核"
        _menu_item 2  "启动 Xray"
        _menu_item 3  "停止 Xray"
        _menu_item 4  "重启 Xray"
        echo ""
        echo -e " ${CYAN}【节点管理】${NC}"
        _menu_item 5  "添加 SS2022+Reality 节点"
        _menu_item 6  "查看所有节点"
        _menu_item 7  "删除节点"
        _menu_item 8  "修改节点端口"
        _menu_item 9  "更新脚本"
        _menu_item 10 "设置网络优先级 (IPv4/IPv6)"
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
            5) _init_xray_config; _add_ss2022_reality; _pause ;;
            6) _view_xray_nodes; _pause ;;
            7) _delete_xray_node; _pause ;;
            8) _modify_xray_port; _pause ;;
            9) _update_script_self; _pause; exit 0 ;;
            10) _choose_ip_preference ;;
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
