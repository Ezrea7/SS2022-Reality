#!/bin/bash

# ============================================================
#   SS2022 + Reality 独立安装管理脚本 (sing-box 单协议版)
# ============================================================

SCRIPT_VERSION="0.1.0"
SCRIPT_CMD_NAME="ss2022"
SCRIPT_CMD_ALIAS="SS2022"
SCRIPT_INSTALL_PATH="/usr/local/bin/${SCRIPT_CMD_NAME}"
SCRIPT_ALIAS_PATH="/usr/local/bin/${SCRIPT_CMD_ALIAS}"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/Ezrea7/SS2022-Reality/refs/heads/main/singbox-modified.sh"
SELF_SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_DIR="/usr/local/etc/sing-box"
SINGBOX_CONFIG="${SINGBOX_DIR}/config.json"
SINGBOX_METADATA="${SINGBOX_DIR}/metadata.json"
SINGBOX_LOG="/var/log/sing-box.log"
SINGBOX_PID_FILE="/tmp/sing-box.pid"
DEFAULT_SNI="support.apple.com"
IP_PREF_FILE="${SINGBOX_DIR}/ip_preference.conf"

export ENABLE_DEPRECATED_LEGACY_DNS_SERVERS="true"
export ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM="true"
export ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER="true"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()    { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
_warn()    { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
_error()   { echo -e "${RED}[错误] $1${NC}" >&2; }

trap 'rm -f "${SINGBOX_DIR}"/*.tmp.* 2>/dev/null || true' EXIT

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

    for c in bash jq openssl awk sed grep tar sha256sum; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing="$missing curl"
    command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || _pkg_install iproute2 net-tools
    if command -v apk >/dev/null 2>&1; then
        [ -f /etc/ssl/certs/ca-certificates.crt ] || missing="$missing ca-certificates"
    fi
    [ -n "$missing" ] && _pkg_install $missing

    for c in bash jq openssl awk sed grep tar sha256sum; do
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
            mkdir -p "$SINGBOX_DIR" 2>/dev/null || true
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
    [ -z "$total_mem_mb" ] && total_mem_mb=128
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

_init_singbox_config() {
    mkdir -p "$SINGBOX_DIR"
    touch "$SINGBOX_LOG" 2>/dev/null || true

    if [ ! -s "$SINGBOX_CONFIG" ]; then
        cat > "$SINGBOX_CONFIG" <<'JSON'
{
  "log": { "disabled": true },
  "inbounds": [],
  "outbounds": [
    { "type": "direct" }
  ]
}
JSON
        _success "sing-box 配置文件已初始化。"
    fi

    [ -s "$SINGBOX_METADATA" ] || echo '{}' > "$SINGBOX_METADATA"
}

_create_singbox_systemd_service() {
    local mem_limit_mb
    mem_limit_mb=$(_get_mem_limit)
    cat > /etc/systemd/system/sing-box.service <<EOF2
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Environment="GOMEMLIMIT=${mem_limit_mb}MiB"
Environment="ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true"
Environment="ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true"
Environment="ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true"
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONFIG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF2
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable sing-box >/dev/null 2>&1 || true
}

_create_singbox_openrc_service() {
    touch "${SINGBOX_LOG}" 2>/dev/null || true
    local mem_limit_mb
    mem_limit_mb=$(_get_mem_limit)
    cat > /etc/init.d/sing-box <<EOF2
#!/sbin/openrc-run

description="sing-box service"
command="${SINGBOX_BIN}"
command_args="run -c ${SINGBOX_CONFIG}"
supervisor="supervise-daemon"
supervise_daemon_args="--env GOMEMLIMIT=${mem_limit_mb}MiB --env ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true --env ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true --env ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true"
respawn_delay=3
respawn_max=0
pidfile="${SINGBOX_PID_FILE}"
output_log="${SINGBOX_LOG}"
error_log="${SINGBOX_LOG}"

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
        *) _warn "未检测到 systemd/openrc，请手动管理 sing-box 进程。" ;;
    esac
}

_get_singbox_core_version() {
    [ -x "$SINGBOX_BIN" ] || { echo "未安装"; return 0; }
    local version
    version=$($SINGBOX_BIN version 2>/dev/null | head -1 | awk '{print $3}')
    [ -n "$version" ] && echo "v${version}" || echo "未知版本"
}

_get_singbox_node_count() {
    [ -f "$SINGBOX_CONFIG" ] || { echo "0"; return 0; }
    jq -r '.inbounds | length' "$SINGBOX_CONFIG" 2>/dev/null || echo "0"
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

_show_singbox_runtime_summary() {
    echo -e " sing-box ${YELLOW}$(_get_singbox_core_version)${NC}: ${GREEN}$(_get_singbox_service_status)${NC} ($(_get_singbox_node_count)节点)"
    echo -e "--------------------------------------------------"
}

_manage_singbox_service() {
    local action="$1" result=1

    [ -x "$SINGBOX_BIN" ] || { _error "sing-box 内核未安装。"; return 1; }
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

    [ "$result" -eq 0 ] || { _error "sing-box 服务${action}失败。"; return 1; }

    case "$action" in
        start) _success "sing-box 服务已启动。" ;;
        stop) _success "sing-box 服务已停止。" ;;
        restart) _success "sing-box 服务已重启。" ;;
    esac
}

_install_or_update_singbox() {
    local is_first_install=false current_ver arch arch_tag libc_suffix api_url search_pattern release_info download_url checksum_url checksums dl_filename expected_hash actual_hash temp_dir version
    [ ! -f "$SINGBOX_BIN" ] && is_first_install=true

    if [ "$is_first_install" = true ]; then
        _info "sing-box 内核未安装，正在执行首次安装..."
    else
        current_ver=$($SINGBOX_BIN version 2>/dev/null | head -1 | awk '{print $3}')
        _info "当前 sing-box 版本: v${current_ver}，正在检查更新..."
    fi

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='armv7' ;;
        *) _error "不支持的架构：$arch"; return 1 ;;
    esac

    libc_suffix=""
    if ldd --version 2>&1 | grep -qi musl || [ -f /etc/alpine-release ]; then
        _info "检测到 musl libc (Alpine 等系统)，将下载 musl 版本..."
        libc_suffix="-musl"
    fi

    api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    search_pattern="linux-${arch_tag}${libc_suffix}.tar.gz"
    release_info=$(curl -s "$api_url")
    download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name | contains(\"${search_pattern}\")) | .browser_download_url" | head -1)
    checksum_url=$(echo "$release_info" | jq -r '.assets[] | select(.name | endswith("checksums.txt")) | .browser_download_url' | head -1)

    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        _error "无法获取 sing-box 下载链接 (搜索: ${search_pattern})。"
        return 1
    fi

    wget -qO sing-box.tar.gz "$download_url" || {
        _error "sing-box 下载失败。"
        return 1
    }

    if [ -n "$checksum_url" ] && [ "$checksum_url" != "null" ]; then
        _info "正在进行 SHA256 完整性校验..."
        checksums=$(wget -qO- "$checksum_url" 2>/dev/null)
        if [ -n "$checksums" ]; then
            dl_filename=$(basename "$download_url")
            expected_hash=$(echo "$checksums" | grep "$dl_filename" | awk '{print $1}')
            if [ -n "$expected_hash" ]; then
                actual_hash=$(sha256sum sing-box.tar.gz | awk '{print $1}')
                if [ "$expected_hash" != "$actual_hash" ]; then
                    _error "SHA256 校验失败，已取消安装。"
                    rm -f sing-box.tar.gz
                    return 1
                fi
                _success "SHA256 校验通过。"
            else
                _warn "校验文件中未找到匹配条目，跳过校验。"
            fi
        else
            _warn "校验文件下载失败，跳过校验。"
        fi
    else
        _warn "未找到 SHA256 校验文件，跳过完整性校验。"
    fi

    temp_dir=$(mktemp -d)
    tar -xzf sing-box.tar.gz -C "$temp_dir" || {
        _error "sing-box 解压失败。"
        rm -f sing-box.tar.gz
        rm -rf "$temp_dir"
        return 1
    }

    mv "$temp_dir"/sing-box-*/sing-box "$SINGBOX_BIN" 2>/dev/null || {
        _error "未找到 sing-box 二进制文件。"
        rm -f sing-box.tar.gz
        rm -rf "$temp_dir"
        return 1
    }
    chmod +x "$SINGBOX_BIN"
    mkdir -p "$SINGBOX_DIR"
    rm -f sing-box.tar.gz
    rm -rf "$temp_dir"

    version=$($SINGBOX_BIN version 2>/dev/null | head -1 | awk '{print $3}')
    _success "sing-box v${version} 安装/更新成功。"

    _init_singbox_config
    _create_singbox_service

    if [ "$is_first_install" = true ]; then
        _info "首次安装 sing-box，正在初始化配置与服务..."
        _set_ip_preference ipv4 >/dev/null 2>&1 || true
        _manage_singbox_service start
        _success "sing-box 首次安装完成并已启动。"
    else
        _manage_singbox_service restart
    fi
}

_generate_reality_keys() {
    local keypair
    keypair=$($SINGBOX_BIN generate reality-keypair 2>&1)
    REALITY_PRIVATE_KEY=$(echo "$keypair" | awk -F': ' '/PrivateKey/ {print $2}' | head -1)
    REALITY_PUBLIC_KEY=$(echo "$keypair" | awk -F': ' '/PublicKey/ {print $2}' | head -1)
    REALITY_SHORT_ID=$(openssl rand -hex 8)

    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
        _error "Reality 密钥生成失败。"
        echo "$keypair" >&2
        return 1
    fi
}

_get_inbound_field() {
    local tag="$1" field="$2"
    jq --arg tag "$tag" -r ".inbounds[] | select(.tag == \$tag) | ${field} // empty" "$SINGBOX_CONFIG" 2>/dev/null
}

_get_meta_field() {
    local tag="$1" field="$2"
    jq --arg tag "$tag" --arg field "$field" -r '.[$tag][$field] // empty' "$SINGBOX_METADATA" 2>/dev/null
}

_get_tag_name() {
    local tag="$1" name
    name=$(_get_meta_field "$tag" name)
    [ -n "$name" ] && printf '%s\n' "$name" || printf '%s\n' "$tag"
}

_get_qx_link() {
    local tag="$1" saved_link built_link
    saved_link=$(_get_meta_field "$tag" qx_link)
    [ -n "$saved_link" ] && { echo "$saved_link"; return 0; }
    built_link=$(_build_qx_link "$tag" 2>/dev/null)
    [ -n "$built_link" ] && { echo "$built_link"; return 0; }
    return 1
}

_show_qx_link() {
    local tag="$1" title="${2:-Quantumult X}" link
    link=$(_get_qx_link "$tag")
    [ -n "$link" ] || { _warn "未能生成分享链接。"; return 1; }
    echo ""
    echo -e "  ${YELLOW}${title}:${NC} ${link}"
    echo ""
}

_list_tags() {
    jq -r '.inbounds[].tag' "$SINGBOX_CONFIG" 2>/dev/null
}

_delete_inbound_by_tag() {
    local tag="$1"
    _atomic_modify_json "$SINGBOX_CONFIG" "del(.inbounds[] | select(.tag == \"$tag\"))" || {
        _error "删除节点配置失败。"
        return 1
    }
}

_update_inbound_port_and_tag() {
    local tag="$1" new_port="$2" new_tag="$3"
    _atomic_modify_json "$SINGBOX_CONFIG" "(.inbounds[] | select(.tag == \"$tag\") | .listen_port) = $new_port | (.inbounds[] | select(.tag == \"$tag\") | .tag) = \"$new_tag\"" || {
        _error "更新节点端口失败。"
        return 1
    }
}

_replace_port_in_text() {
    local text="$1" old_port="$2" new_port="$3"
    printf '%s' "$text" | sed "s/:${old_port}/:${new_port}/g; s/-${old_port}/-${new_port}/g"
}

_set_meta_field() {
    local tag="$1" key="$2" value="$3"
    _atomic_modify_json "$SINGBOX_METADATA" ".\"$tag\".\"$key\" = \"$value\"" >/dev/null 2>&1
}

_save_meta() {
    local tag="$1" name="$2" link="$3"
    shift 3

    _atomic_modify_json "$SINGBOX_METADATA" ". + {\"$tag\": {name: \"$name\", qx_link: \"$link\"}}" || return 1

    for pair in "$@"; do
        local key="${pair%%=*}" val="${pair#*=}"
        [ -n "$key" ] && [ -n "$val" ] || continue
        _set_meta_field "$tag" "$key" "$val" || true
    done
}

_build_qx_link() {
    local tag="$1"
    local port name method password sni public_key short_id server_ip link_ip

    port=$(_get_inbound_field "$tag" '.listen_port')
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

_has_nodes() {
    [ -f "$SINGBOX_CONFIG" ] && jq -e '.inbounds | length > 0' "$SINGBOX_CONFIG" >/dev/null 2>&1
}

_select_tag() {
    local prompt="$1" choice i=1
    local -a tags
    mapfile -t tags < <(_list_tags)
    [ "${#tags[@]}" -gt 0 ] || return 1

    echo "" >&2
    echo -e "${YELLOW}${prompt}${NC}" >&2
    for tag in "${tags[@]}"; do
        echo -e "  ${GREEN}[${i}]${NC} $(_get_tag_name "$tag") (端口: $(_get_inbound_field "$tag" '.listen_port'))" >&2
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

    local node_ip custom_ip port sni custom_sni default_name custom_name name tag method password link_ip inbound qx_link
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
        if jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null 2>&1; then
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

    inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg method "$method" --arg password "$password" --arg sni "$sni" --arg pk "$REALITY_PRIVATE_KEY" --arg sid "$REALITY_SHORT_ID" '
        {
          "type": "shadowsocks",
          "tag": $tag,
          "listen": "::",
          "listen_port": $port,
          "method": $method,
          "password": $password,
          "network": "tcp",
          "tls": {
            "enabled": true,
            "server_name": $sni,
            "reality": {
              "enabled": true,
              "handshake": {
                "server": $sni,
                "server_port": 443
              },
              "private_key": $pk,
              "short_id": [$sid]
            }
          }
        }')

    _atomic_modify_json "$SINGBOX_CONFIG" ".inbounds += [$inbound]" || return 1

    qx_link="shadowsocks=${link_ip}:${port}, method=${method}, password=${password}, obfs=over-tls, obfs-host=${sni}, tls-verification=true, reality-base64-pubkey=${REALITY_PUBLIC_KEY}, reality-hex-shortid=${REALITY_SHORT_ID}, udp-relay=true, tag=${name}"

    _save_meta "$tag" "$name" "$qx_link" \
        "password=${password}" \
        "publicKey=${REALITY_PUBLIC_KEY}" \
        "shortId=${REALITY_SHORT_ID}" \
        "server=${node_ip}" \
        "sni=${sni}" \
        "method=${method}"

    _manage_singbox_service restart
    _success "SS2022+Reality 节点 [${name}] 添加成功。"
    _show_qx_link "$tag"
}

_view_nodes() {
    if ! _has_nodes; then
        _warn "当前没有 sing-box 节点。"
        return
    fi

    echo ""
    echo -e "${YELLOW}══════════════════ sing-box 节点列表 ══════════════════${NC}"
    local count=0 tag port method sni name link
    while IFS= read -r tag; do
        count=$((count + 1))
        port=$(_get_inbound_field "$tag" '.listen_port')
        method=$(_get_inbound_field "$tag" '.method')
        sni=$(_get_inbound_field "$tag" '.tls.server_name')
        name=$(_get_tag_name "$tag")
        link=$(_get_qx_link "$tag")
        echo ""
        echo -e "  ${GREEN}[${count}]${NC} ${CYAN}${name}${NC}"
        echo -e "      协议: ${YELLOW}shadowsocks+reality${NC}  |  端口: ${GREEN}${port}${NC}  |  方法: ${YELLOW}${method}${NC}"
        echo -e "      SNI: ${CYAN}${sni}${NC}  |  标签: ${CYAN}${tag}${NC}"
        if [ -n "$link" ]; then
            echo -e "      ${YELLOW}Quantumult X:${NC} ${link}"
        else
            echo -e "      ${RED}Quantumult X: 无法生成链接${NC}"
        fi
    done < <(_list_tags)
}

_delete_node() {
    if ! _has_nodes; then
        _warn "当前没有 sing-box 节点。"
        return
    fi

    local target_tag target_name confirm
    target_tag=$(_select_tag "══════════ 选择要删除的节点 ══════════") || return
    target_name=$(_get_tag_name "$target_tag")
    read -p "确定删除 [${target_name}]? (y/N): " confirm
    _confirm_yes "$confirm" || { _info "已取消。"; return; }

    _delete_inbound_by_tag "$target_tag" || return 1
    _atomic_modify_json "$SINGBOX_METADATA" "del(.\"$target_tag\")" >/dev/null 2>&1 || true
    _manage_singbox_service restart
    _success "节点 [${target_name}] 已删除。"
}

_modify_node_port() {
    if ! _has_nodes; then
        _warn "当前没有 sing-box 节点。"
        return
    fi

    local target_tag old_port target_name new_port new_tag new_name old_qx_link new_link tmp
    target_tag=$(_select_tag "══════════ 选择要修改端口的节点 ══════════") || return
    old_port=$(_get_inbound_field "$target_tag" '.listen_port')
    target_name=$(_get_tag_name "$target_tag")

    [ -n "$old_port" ] && [ "$old_port" != "null" ] || { _error "未找到目标节点端口。"; return 1; }

    _info "当前端口: ${old_port}"
    new_port=$(_input_port)
    [ "$new_port" = "$old_port" ] && { _info "新端口与当前端口一致，无需修改。"; return 0; }

    new_tag=$(printf '%s' "$target_tag" | sed "s/${old_port}/${new_port}/g")
    new_name=$(printf '%s' "$target_name" | sed "s/${old_port}/${new_port}/g")
    [ -n "$new_tag" ] || new_tag="$target_tag"
    [ -n "$new_name" ] || new_name="$target_name"

    if [ "$new_tag" != "$target_tag" ] && jq -e --arg tag "$new_tag" '.inbounds[] | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null 2>&1; then
        _error "修改后的节点标签已存在，请调整节点名称后再试。"
        return 1
    fi

    old_qx_link=$(_get_qx_link "$target_tag")
    _update_inbound_port_and_tag "$target_tag" "$new_port" "$new_tag" || return 1

    new_link=$(_replace_port_in_text "$old_qx_link" "$old_port" "$new_port")
    [ -n "$new_link" ] || new_link=$(_build_qx_link "$new_tag" 2>/dev/null)
    tmp="${SINGBOX_METADATA}.tmp.$$"
    jq --arg ot "$target_tag" --arg nt "$new_tag" --arg n "$new_name" --arg l "$new_link" '. + {($nt): ((.[$ot] // {}) + {name: $n, qx_link: $l})} | del(.[$ot])' "$SINGBOX_METADATA" > "$tmp" 2>/dev/null && mv "$tmp" "$SINGBOX_METADATA" || {
        rm -f "$tmp"
        _error "更新节点元数据失败。"
        return 1
    }

    _manage_singbox_service restart
    _success "节点 [${new_name}] 端口已改为 ${new_port}。"
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

    rm -f "$SINGBOX_BIN" "$SINGBOX_LOG" "$SINGBOX_PID_FILE"
    rm -rf "$SINGBOX_DIR"
}

_uninstall_singbox() {
    echo ""
    _warn "即将卸载 sing-box 内核及其所有配置！"
    printf "${YELLOW}确定要卸载吗? (y/N): ${NC}"
    read -r confirm
    _confirm_yes "$confirm" || { _info "卸载已取消。"; return; }

    _cleanup_singbox_files
    _success "sing-box 内核已完全卸载！"
}

_uninstall_script() {
    _warn "！！！警告！！！"
    _warn "本操作将停止并禁用 sing-box 服务，"
    _warn "删除所有相关文件（包括二进制、配置文件、快捷命令及脚本本体）。"

    echo ""
    echo "即将删除以下内容："
    echo -e "  ${RED}-${NC} sing-box 配置目录: ${SINGBOX_DIR}"
    echo -e "  ${RED}-${NC} sing-box 二进制: ${SINGBOX_BIN}"
    echo -e "  ${RED}-${NC} 系统快捷命令: ${SCRIPT_INSTALL_PATH}"
    [ "$SCRIPT_ALIAS_PATH" != "$SCRIPT_INSTALL_PATH" ] && echo -e "  ${RED}-${NC} 系统快捷命令: ${SCRIPT_ALIAS_PATH}"
    [ -n "$SELF_SCRIPT_PATH" ] && [ -f "$SELF_SCRIPT_PATH" ] && echo -e "  ${RED}-${NC} 管理脚本: ${SELF_SCRIPT_PATH}"
    echo ""

    printf "${YELLOW}确定要执行卸载吗? (y/N): ${NC}"
    read -r confirm_main
    _confirm_yes "$confirm_main" || { _info "卸载已取消。"; return; }

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

_singbox_menu() {
    while true; do
        clear
        echo ""
        echo -e "=================================================="
        echo -e " sing-box 独立脚本 v${SCRIPT_VERSION}"
        echo -e " 单协议: SS2022 + Reality"
        _show_singbox_runtime_summary
        echo -e "=================================================="
        echo -e " ${CYAN}【服务控制】${NC}"
        _menu_item 1  "安装/更新 sing-box 内核"
        _menu_item 2  "启动 sing-box"
        _menu_item 3  "停止 sing-box"
        _menu_item 4  "重启 sing-box"
        echo ""
        echo -e " ${CYAN}【节点管理】${NC}"
        _menu_item 5  "添加 SS2022+Reality 节点"
        _menu_item 6  "查看所有节点"
        _menu_item 7  "删除节点"
        _menu_item 8  "修改节点端口"
        _menu_item 9  "更新脚本"
        _menu_item 10 "设置网络优先级 (IPv4/IPv6)"
        echo ""
        _menu_danger 88 "卸载 sing-box"
        _menu_danger 99 "卸载脚本"
        _menu_exit 0 "退出脚本"
        echo -e "=================================================="
        read -p "请选择 [0-99]: " choice

        case "$choice" in
            1) _install_or_update_singbox; _pause ;;
            2) [ -f "$SINGBOX_BIN" ] && _manage_singbox_service start; _pause ;;
            3) [ -f "$SINGBOX_BIN" ] && _manage_singbox_service stop; _pause ;;
            4) [ -f "$SINGBOX_BIN" ] && _manage_singbox_service restart; _pause ;;
            5) _init_singbox_config; _add_ss2022_reality; _pause ;;
            6) _view_nodes; _pause ;;
            7) _delete_node; _pause ;;
            8) _modify_node_port; _pause ;;
            9) _update_script_self; _pause; exit 0 ;;
            10) _choose_ip_preference ;;
            88) _uninstall_singbox; _pause ;;
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
    if [ -f "$SINGBOX_BIN" ]; then
        _init_singbox_config
        _create_singbox_service >/dev/null 2>&1 || true
    fi
    _singbox_menu
}

_main "$@"
