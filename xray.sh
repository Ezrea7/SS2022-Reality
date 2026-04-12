#!/bin/bash

# ============================================================
#      Xray SS2022 + Reality 极致优化版
#      特性：零日志 | 智能IP | 内存优化 | 生产级稳定
# ============================================================

SCRIPT_VERSION="4.0.0-ultimate"
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
XRAY_LOG="/dev/null"  # 日志直接丢弃
XRAY_PID_FILE="/tmp/xray.pid"
DEFAULT_SNI="www.amd.com"

# IP preference - 严格遵循此设置输出节点
IP_PREF_FILE="${XRAY_DIR}/ip_preference.conf"

# 内存优化配置
GOMEMLIMIT_PERCENT=80      # 使用80%可用内存给Go
GOGC_VALUE=off               # 禁用自动GC，完全由GOMEMLIMIT控制
MAX_MEM_LIMIT=$((6*1024*1024*1024))  # 6GB上限
MIN_MEM_LIMIT=$((64*1024*1024))      # 64MB下限

# 颜色配置 - 使用tput提高兼容性
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ $ncolors -ge 8 ]; then
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        CYAN=$(tput setaf 6)
        BOLD=$(tput bold)
        NC=$(tput sgr0)
    else
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        NC='\033[0m'
    fi
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
fi

# 日志函数 - 仅输出到控制台，绝不写文件
_log() {
    local level="$1" msg="$2" color="$3"
    echo -e "${color}[$(date '+%H:%M:%S')] [${level}] ${msg}${NC}" >&2
}

_info()    { _log "INFO" "$1" "$CYAN"; }
_success() { _log "OK" "$1" "$GREEN"; }
_warn()    { _log "WARN" "$1" "$YELLOW"; }
_error()   { _log "ERR" "$1" "$RED"; }

_pause() {
    echo ""
    read -r -p "按回车键继续..." _
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
    if [ "${EUID}" -ne 0 ]; then
        _error "请使用 root 权限运行"
        exit 1
    fi
}

_detect_init_system() {
    if [ -f /sbin/openrc-run ] || command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="unknown"
    fi
}

# 包管理器检测 - 带缓存
_pkg_manager=""
_detect_pkg_manager() {
    [ -n "$_pkg_manager" ] && return 0
    if command -v apk >/dev/null 2>&1; then
        _pkg_manager="apk"
    elif command -v apt-get >/dev/null 2>&1; then
        _pkg_manager="apt"
    elif command -v dnf >/dev/null 2>&1; then
        _pkg_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
        _pkg_manager="yum"
    else
        return 1
    fi
    return 0
}

_pkg_install() {
    [ $# -eq 0 ] && return 0
    _detect_pkg_manager || { _warn "未检测到包管理器"; return 1; }
    
    case "$_pkg_manager" in
        apk)  apk add --no-cache "$@" >/dev/null 2>&1 ;;
        apt)  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
              DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
        dnf)  dnf install -y "$@" >/dev/null 2>&1 ;;
        yum)  yum install -y "$@" >/dev/null 2>&1 ;;
    esac
}

_ensure_deps() {
    local missing=()
    for c in jq openssl awk sed grep; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing+=("curl")
    command -v unzip >/dev/null 2>&1 || missing+=("unzip")
    command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || _pkg_install iproute2 net-tools
    
    [ ${#missing[@]} -gt 0 ] && _pkg_install "${missing[@]}"
}

_install_script_shortcut() {
    local src
    src="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    [ -n "$src" ] && [ -f "$src" ] || return 0

    mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")" 2>/dev/null || return 0

    if [ "$src" != "$SCRIPT_INSTALL_PATH" ]; then
        cp -f "$src" "$SCRIPT_INSTALL_PATH" 2>/dev/null || return 0
    fi
    chmod +x "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
    ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH" 2>/dev/null || \
        cp -f "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_ALIAS_PATH" 2>/dev/null || true
}

_update_script_self() {
    local tmp="/tmp/${SCRIPT_CMD_NAME}.update.$$"
    local src
    src="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

    if command -v curl >/dev/null 2>&1; then
        curl -LfsS --connect-timeout 10 --max-time 30 "$SCRIPT_UPDATE_URL" -o "$tmp" 2>/dev/null || {
            rm -f "$tmp"; _error "下载失败"; return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 "$SCRIPT_UPDATE_URL" -O "$tmp" 2>/dev/null || {
            rm -f "$tmp"; _error "下载失败"; return 1
        }
    else
        _error "未找到 curl/wget"
        return 1
    fi

    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        _error "语法校验失败"
        return 1
    fi

    local new_version
    new_version=$(grep -E '^SCRIPT_VERSION=' "$tmp" | head -1 | cut -d'"' -f2)
    [ "$new_version" = "$SCRIPT_VERSION" ] && {
        _success "当前已是最新版本"
        rm -f "$tmp"
        return 0
    }

    cp -f "$tmp" "$SCRIPT_INSTALL_PATH" || { rm -f "$tmp"; return 1; }
    chmod +x "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
    
    if [ -n "$src" ] && [ -f "$src" ] && [ "$src" != "$SCRIPT_INSTALL_PATH" ]; then
        cp -f "$tmp" "$src" 2>/dev/null || true
        chmod +x "$src" 2>/dev/null || true
    fi

    rm -f "$tmp"
    ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_ALIAS_PATH" 2>/dev/null || true

    _success "已更新: ${SCRIPT_VERSION} -> ${new_version}"
    _warn "请重新运行脚本以加载新版本"
}

# ============================================================
# IP 管理 - 严格根据优先级获取和输出
# ============================================================

# 缓存IP避免重复检测
_ipv4_cache=""
_ipv6_cache=""

_get_ipv4() {
    [ -n "$_ipv4_cache" ] && { echo "$_ipv4_cache"; return; }
    local ip=""
    local services=("https://ipv4.icanhazip.com" "https://v4.ident.me" "https://api4.ipify.org")
    
    for svc in "${services[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            ip=$(curl -s4 --connect-timeout 3 --max-time 5 "$svc" 2>/dev/null)
        else
            ip=$(wget -qO- -4 --timeout=5 "$svc" 2>/dev/null)
        fi
        [ -n "$ip" ] && break
    done
    
    _ipv4_cache="$ip"
    echo "$ip"
}

_get_ipv6() {
    [ -n "$_ipv6_cache" ] && { echo "$_ipv6_cache"; return; }
    local ip=""
    local services=("https://ipv6.icanhazip.com" "https://v6.ident.me" "https://api6.ipify.org")
    
    for svc in "${services[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            ip=$(curl -s6 --connect-timeout 3 --max-time 5 "$svc" 2>/dev/null)
        else
            ip=$(wget -qO- -6 --timeout=5 "$svc" 2>/dev/null)
        fi
        [ -n "$ip" ] && break
    done
    
    _ipv6_cache="$ip"
    echo "$ip"
}

_get_public_ip() {
    local pref
    pref=$(_get_ip_preference)
    
    if [ "$pref" = "ipv6" ]; then
        local ip6
        ip6=$(_get_ipv6)
        [ -n "$ip6" ] && { echo "$ip6"; return; }
        _get_ipv4
    else
        local ip4
        ip4=$(_get_ipv4)
        [ -n "$ip4" ] && { echo "$ip4"; return; }
        _get_ipv6
    fi
}

# 根据优先级获取用于节点输出的IP
_get_node_ip() {
    local pref
    pref=$(_get_ip_preference)
    
    if [ "$pref" = "ipv6" ]; then
        local ip6
        ip6=$(_get_ipv6)
        [ -n "$ip6" ] && { echo "$ip6"; return; }
        _warn "IPv6优先但未检测到，回退到IPv4"
        _get_ipv4
    else
        local ip4
        ip4=$(_get_ipv4)
        [ -n "$ip4" ] && { echo "$ip4"; return; }
        _warn "IPv4优先但未检测到，回退到IPv6"
        _get_ipv6
    fi
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

_set_ip_preference() {
    local pref="$1"
    case "$pref" in
        ipv4|ipv6)
            mkdir -p "$XRAY_DIR" 2>/dev/null || true
            echo "$pref" > "$IP_PREF_FILE" 2>/dev/null || return 1
            _apply_system_ip_preference "$pref"
            # 清除缓存
            _ipv4_cache=""
            _ipv6_cache=""
            return 0
            ;;
        *) return 1 ;;
    esac
}

_apply_system_ip_preference() {
    local pref="$1"
    local gai_conf="/etc/gai.conf"
    
    [ -f "$gai_conf" ] || touch "$gai_conf"
    
    if [ ! -f "${gai_conf}.bak" ]; then
        cp -a "$gai_conf" "${gai_conf}.bak" 2>/dev/null || true
    fi
    
    # 注释掉所有现有的优先级规则
    sed -i -e "/^[[:space:]]*precedence[[:space:]]*::ffff:0:0\/96/ s/^/#/" "$gai_conf"
    
    if [ "$pref" = "ipv4" ]; then
        if ! grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' "$gai_conf"; then
            echo 'precedence ::ffff:0:0/96 100' >> "$gai_conf"
        fi
    fi
}

_choose_ip_preference() {
    local current
    current=$(_get_ip_preference)
    
    local ip4 ip6
    ip4=$(_get_ipv4)
    ip6=$(_get_ipv6)
    
    echo ""
    local display_pref
    [ "$current" = "ipv6" ] && display_pref="IPv6" || display_pref="IPv4"
    echo -e "${CYAN}当前网络优先级: ${BOLD}${display_pref} 优先${NC}"
    echo ""
    echo -e "检测到 IPv4: ${YELLOW}${ip4:-无}${NC}"
    echo -e "检测到 IPv6: ${YELLOW}${ip6:-无}${NC}"
    echo ""
    echo "请选择:"
    echo -e "  ${GREEN}[1]${NC} IPv4 优先 (默认)"
    echo -e "  ${GREEN}[2]${NC} IPv6 优先"
    echo -e "  ${YELLOW}[0]${NC} 返回"
    
    read -r -p "请选择 [0-2]: " choice
    case "$choice" in
        1) _set_ip_preference ipv4 && _success "已设置 IPv4 优先" || _error "设置失败" ;;
        2) _set_ip_preference ipv6 && _success "已设置 IPv6 优先" || _error "设置失败" ;;
        0) return 0 ;;
        *) _error "无效输入" ;;
    esac
    _pause
}

# ============================================================
# 内存管理 - 极致优化
# ============================================================

_get_meminfo_total_mb() {
    local total_mem_mb=0
    total_mem_mb=$(awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    
    if ! [[ "$total_mem_mb" =~ ^[0-9]+$ ]] || [ "$total_mem_mb" -le 0 ]; then
        if command -v free >/dev/null 2>&1; then
            total_mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
        fi
    fi
    
    if ! [[ "$total_mem_mb" =~ ^[0-9]+$ ]] || [ "$total_mem_mb" -le 0 ]; then
        total_mem_mb=256  # 保守默认值
    fi
    echo "$total_mem_mb"
}

_is_likely_container() {
    if command -v systemd-detect-virt >/dev/null 2>&1 && \
       systemd-detect-virt -cq >/dev/null 2>&1; then
        return 0
    fi
    
    if [ -f /proc/1/environ ] && \
       grep -qaE '(lxc|docker|container|kubepods|podman)' /proc/1/environ 2>/dev/null; then
        return 0
    fi
    
    if [ -f /proc/self/cgroup ] && \
       grep -qaE '(lxc|docker|container|kubepods|podman)' /proc/self/cgroup 2>/dev/null; then
        return 0
    fi
    
    return 1
}

_read_first_cgroup_value() {
    local mode="$1"
    shift
    local path raw bytes mb
    
    for path in "$@"; do
        [ -n "$path" ] || continue
        [ -r "$path" ] || continue
        
        raw=$(tr -d '[:space:]' < "$path" 2>/dev/null)
        [ -n "$raw" ] || continue
        
        if [ "$mode" = "limit" ] && [ "$raw" = "max" ]; then
            continue
        fi
        
        [[ "$raw" =~ ^[0-9]+$ ]] || continue
        
        if [ "$mode" = "limit" ] && [ "$raw" -ge 9223372036854770000 ] 2>/dev/null; then
            continue
        fi
        
        bytes=$raw
        mb=$((bytes / 1024 / 1024))
        [ "$mb" -ge 0 ] || continue
        
        if [ "$mode" = "limit" ] && [ "$mb" -le 0 ]; then
            continue
        fi
        
        echo "$mb"
        return 0
    done
    return 1
}

_get_cgroup_limit_mb() {
    local cg2_rel cg1_rel mp paths=()

    paths+=(/sys/fs/cgroup/memory.max)
    paths+=(/sys/fs/cgroup/memory/memory.limit_in_bytes)

    cg2_rel=$(awk -F: '$1=="0"{print $3; exit}' /proc/self/cgroup 2>/dev/null)
    cg1_rel=$(awk -F: '$2 ~ /(^|,)memory(,|$)/{print $3; exit}' /proc/self/cgroup 2>/dev/null)

    if [ -n "$cg2_rel" ] && [ "$cg2_rel" != "/" ]; then
        paths+=("/sys/fs/cgroup${cg2_rel}/memory.max")
    fi
    if [ -n "$cg1_rel" ] && [ "$cg1_rel" != "/" ]; then
        paths+=("/sys/fs/cgroup/memory${cg1_rel}/memory.limit_in_bytes")
        paths+=("/sys/fs/cgroup${cg1_rel}/memory.limit_in_bytes")
    fi

    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        paths+=("${mp}/memory.max")
        [ -n "$cg2_rel" ] && [ "$cg2_rel" != "/" ] && paths+=("${mp}${cg2_rel}/memory.max")
    done < <(awk '$0 ~ / - cgroup2 / {print $5}' /proc/self/mountinfo 2>/dev/null)

    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        paths+=("${mp}/memory.limit_in_bytes")
        [ -n "$cg1_rel" ] && [ "$cg1_rel" != "/" ] && paths+=("${mp}${cg1_rel}/memory.limit_in_bytes")
    done < <(awk '$0 ~ / - cgroup / && $0 ~ /(^|,)memory(,|$)/ {print $5}' /proc/self/mountinfo 2>/dev/null)

    _read_first_cgroup_value limit $(printf '%s\n' "${paths[@]}" | awk '!seen[$0]++')
}

_get_effective_total_mem_mb() {
    local meminfo_mb cgroup_mb
    meminfo_mb=$(_get_meminfo_total_mb)
    cgroup_mb=$(_get_cgroup_limit_mb 2>/dev/null || true)

    # 容器环境优先使用cgroup限制
    if [[ "$cgroup_mb" =~ ^[0-9]+$ ]] && [ "$cgroup_mb" -gt 0 ] && [ "$cgroup_mb" -lt "$meminfo_mb" ]; then
        echo "$cgroup_mb"
        return 0
    fi

    # 容器环境回退
    if _is_likely_container && [ "$meminfo_mb" -gt 1024 ]; then
        echo 1024  # 容器环境保守值1GB
        return 0
    fi

    echo "$meminfo_mb"
}

# 计算GOMEMLIMIT - 生产级优化
_get_mem_limit() {
    local effective_mem_mb mem_limit_bytes
    
    effective_mem_mb=$(_get_effective_total_mem_mb)
    
    if ! [[ "$effective_mem_mb" =~ ^[0-9]+$ ]] || [ "$effective_mem_mb" -le 0 ]; then
        echo 0
        return 0
    fi
    
    # 计算百分比
    mem_limit_bytes=$((effective_mem_mb * 1024 * 1024 * GOMEMLIMIT_PERCENT / 100))
    
    # 应用安全限制
    if [ "$mem_limit_bytes" -gt "$MAX_MEM_LIMIT" ]; then
        mem_limit_bytes=$MAX_MEM_LIMIT
    elif [ "$mem_limit_bytes" -lt "$MIN_MEM_LIMIT" ]; then
        mem_limit_bytes=$MIN_MEM_LIMIT
    fi
    
    echo "$mem_limit_bytes"
}

# 格式化字节为可读格式
_format_bytes() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1024/1024/1024}")GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.0f\", $bytes/1024/1024}")MB"
    else
        echo "$(awk "BEGIN {printf \"%.0f\", $bytes/1024}")KB"
    fi
}

# ============================================================
# 端口检测 - 健壮性优化
# ============================================================

_check_port_occupied() {
    local port="$1"
    
    # 方法1: ss命令
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -qE ":${port}\s" && return 0
        ss -lnu 2>/dev/null | grep -qE ":${port}\s" && return 0
    fi
    
    # 方法2: netstat命令
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -qE ":${port}\s" && return 0
        netstat -lnu 2>/dev/null | grep -qE ":${port}\s" && return 0
    fi
    
    # 方法3: /proc/net直接读取 (最轻量)
    local hex_port
    hex_port=$(printf "%04X" "$port")
    grep -qE "^[[:space:]]*[0-9A-Fa-f]+:[${hex_port}]" /proc/net/tcp 2>/dev/null && return 0
    grep -qE "^[[:space:]]*[0-9A-Fa-f]+:[${hex_port}]" /proc/net/udp 2>/dev/null && return 0
    
    return 1
}

_check_xray_port_conflict() {
    local port="$1"
    
    if _check_port_occupied "$port"; then
        _error "端口 ${port} 已被占用"
        return 0
    fi
    
    if [ -f "$XRAY_CONFIG" ] && \
       jq -e ".inbounds[] | select(.port == $port)" "$XRAY_CONFIG" >/dev/null 2>&1; then
        _error "端口 ${port} 已被Xray使用"
        return 0
    fi
    
    return 1
}

_input_port() {
    local port=""
    
    while true; do
        read -r -p "请输入监听端口: " port
        [[ -z "$port" ]] && _error "端口不能为空" && continue
        
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            _error "无效端口号 (1-65535)"
            continue
        fi
        
        _check_xray_port_conflict "$port" && continue
        break
    done
    
    echo "$port"
}

# ============================================================
# 配置管理 - 零日志设计
# ============================================================

_init_xray_config() {
    mkdir -p "$XRAY_DIR"
    
    if [ ! -s "$XRAY_CONFIG" ]; then
        # 完全禁用日志输出
        cat > "$XRAY_CONFIG" <<'JSON'
{
  "log": {
    "loglevel": "none",
    "access": "none",
    "error": "none"
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
        _success "Xray配置已初始化 (零日志模式)"
    fi
    
    [ -s "$XRAY_METADATA" ] || echo '{}' > "$XRAY_METADATA"
}

_atomic_modify_json() {
    local file="$1" filter="$2"
    local tmp="${file}.tmp.$$"
    
    if jq "$filter" "$file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
        return 0
    else
        rm -f "$tmp"
        _error "JSON修改失败"
        return 1
    fi
}

# ============================================================
# 服务管理 - 零日志 + 内存优化
# ============================================================

_create_xray_systemd_service() {
    local mem_limit mem_limit_fmt
    mem_limit=$(_get_mem_limit)
    mem_limit_fmt=$(_format_bytes "$mem_limit")
    
    local env_lines=""
    if [ -n "$mem_limit" ] && [ "$mem_limit" != "0" ] && [ "$mem_limit" -gt 0 ]; then
        env_lines="Environment=\"GOMEMLIMIT=${mem_limit}\"
Environment=\"GOGC=${GOGC_VALUE}\""
        _info "内存限制: ${mem_limit_fmt} (${GOMEMLIMIT_PERCENT}% of available)"
        _info "GC策略: GOGC=${GOGC_VALUE}"
    fi
    
    # 完全禁用所有日志输出
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service (SS2022+Reality) - Zero Log Mode
Documentation=https://xtls.github.io/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
${env_lines}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=3
LimitNOFILE=65535
LimitNPROC=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${XRAY_DIR}
# 零日志配置 - 所有输出丢弃
StandardOutput=null
StandardError=null
SyslogIdentifier=xray

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable xray >/dev/null 2>&1 || true
}

_create_xray_openrc_service() {
    local mem_limit mem_limit_fmt
    mem_limit=$(_get_mem_limit)
    mem_limit_fmt=$(_format_bytes "$mem_limit")
    
    local env_exports=""
    if [ -n "$mem_limit" ] && [ "$mem_limit" != "0" ] && [ "$mem_limit" -gt 0 ]; then
        env_exports="export GOMEMLIMIT=${mem_limit}
export GOGC=${GOGC_VALUE}"
        _info "内存限制: ${mem_limit_fmt}"
        _info "GC策略: GOGC=${GOGC_VALUE}"
    fi
    
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service (SS2022+Reality) - Zero Log Mode"
command="${XRAY_BIN}"
command_args="run -c ${XRAY_CONFIG}"
command_background=true
pidfile="${XRAY_PID_FILE}"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=3
respawn_period=60

# 环境变量 - 内存优化
${env_exports}

depend() {
    need net
    after firewall dns
}

start_pre() {
    checkpath -d -m 0755 -o root:root "${XRAY_DIR}" 2>/dev/null || true
}
EOF
    
    chmod +x /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
}

_create_xray_service() {
    case "$INIT_SYSTEM" in
        systemd) _create_xray_systemd_service ;;
        openrc)  _create_xray_openrc_service ;;
        *) _warn "未检测到服务管理器" ;;
    esac
}

_manage_xray_service() {
    local action="$1"
    
    case "$INIT_SYSTEM" in
        systemd)
            if [ "$action" = "status" ]; then
                systemctl status xray --no-pager 2>/dev/null || true
                return
            fi
            
            if systemctl "$action" xray >/dev/null 2>&1; then
                case "$action" in
                    start) _success "Xray已启动" ;;
                    stop) _success "Xray已停止" ;;
                    restart) _success "Xray已重启" ;;
                esac
            else
                _error "Xray ${action}失败"
                return 1
            fi
            ;;
        openrc)
            if [ "$action" = "status" ]; then
                rc-service xray status 2>/dev/null || true
                return
            fi
            
            if rc-service xray "$action" >/dev/null 2>&1; then
                case "$action" in
                    start) _success "Xray已启动" ;;
                    stop) _success "Xray已停止" ;;
                    restart) _success "Xray已重启" ;;
                esac
            else
                _error "Xray ${action}失败"
                return 1
            fi
            ;;
        *)
            _warn "未检测到服务管理器"
            ;;
    esac
}

_view_xray_log() {
    _warn "当前为零日志模式，无日志可查看"
    _info "如需查看日志，请修改配置文件: ${XRAY_CONFIG}"
    _info "将 loglevel 从 \"none\" 改为 \"warning\" 或 \"info\""
}

# ============================================================
# Xray核心管理
# ============================================================

_install_or_update_xray() {
    local is_first_install=false
    [ ! -f "$XRAY_BIN" ] && is_first_install=true

    if [ "$is_first_install" = true ]; then
        _info "首次安装Xray..."
    else
        local current_ver
        current_ver=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
        _info "当前版本: v${current_ver}，检查更新..."
    fi

    command -v unzip >/dev/null 2>&1 || _pkg_install unzip

    local arch xray_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  xray_arch="64" ;;
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        armv7l)        xray_arch="arm32-v7a" ;;
        armv8l)        xray_arch="arm64-v8a" ;;
        *)             xray_arch="64" ;;
    esac

    local download[Unit]
Description=Xray Service (SS2022+Reality) - Zero Log Mode
Documentation=https://xtls.github.io/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
${env_lines}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=3
LimitNOFILE=65535
LimitNPROC=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${XRAY_DIR}
# 零日志配置 - 所有输出丢弃
StandardOutput=null
StandardError=null
SyslogIdentifier=xray

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable xray >/dev/null 2>&1 || true
}

_create_xray_openrc_service() {
    local mem_limit mem_limit_fmt
    mem_limit=$(_get_mem_limit)
    mem_limit_fmt=$(_format_bytes "$mem_limit")
    
    local env_exports=""
    if [ -n "$mem_limit" ] && [ "$mem_limit" != "0" ] && [ "$mem_limit" -gt 0 ]; then
        env_exports="export GOMEMLIMIT=${mem_limit}
export GOGC=${GOGC_VALUE}"
        _info "内存限制: ${mem_limit_fmt}"
        _info "GC策略: GOGC=${GOGC_VALUE}"
    fi
    
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service (SS2022+Reality) - Zero Log Mode"
command="${XRAY_BIN}"
command_args="run -c ${XRAY_CONFIG}"
command_background=true
pidfile="${XRAY_PID_FILE}"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=3
respawn_period=60

# 环境变量 - 内存优化
${env_exports}

depend() {
    need net
    after firewall dns
}

start_pre() {
    checkpath -d -m 0755 -o root:root "${XRAY_DIR}" 2>/dev/null || true
}
EOF
    
    chmod +x /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
}

_create_xray_service() {
    case "$INIT_SYSTEM" in
        systemd) _create_xray_systemd_service ;;
        openrc)  _create_xray_openrc_service ;;
        *) _warn "未检测到服务管理器" ;;
    esac
}

_manage_xray_service() {
    local action="$1"
    
    case "$INIT_SYSTEM" in
        systemd)
            if [ "$action" = "status" ]; then
                systemctl status xray --no-pager 2>/dev/null || true
                return
            fi
            
            if systemctl "$action" xray >/dev/null 2>&1; then
                case "$action" in
                    start) _success "Xray已启动" ;;
                    stop) _success "Xray已停止" ;;
                    restart) _success "Xray已重启" ;;
                esac
            else
                _error "Xray ${action}失败"
                return 1
            fi
            ;;
        openrc)
            if [ "$action" = "status" ]; then
                rc-service xray status 2>/dev/null || true
                return
            fi
            
            if rc-service xray "$action" >/dev/null 2>&1; then
                case "$action" in
                    start) _success "Xray已启动" ;;
                    stop) _success "Xray已停止" ;;
                    restart) _success "Xray已重启" ;;
                esac
            else
                _error "Xray ${action}失败"
                return 1
            fi
            ;;
        *)
            _warn "未检测到服务管理器"
            ;;
    esac
}

_view_xray_log() {
    _warn "当前为零日志模式，无日志可查看"
    _info "如需查看日志，请修改配置文件: ${XRAY_CONFIG}"
    _info "将 loglevel 从 \"none\" 改为 \"warning\" 或 \"info\""
}

# ============================================================
# Xray核心管理
# ============================================================

_install_or_update_xray() {
    local is_first_install=false
    [ ! -f "$XRAY_BIN" ] && is_first_install=true

    if [ "$is_first_install" = true ]; then
        _info "首次安装Xray..."
    else
        local current_ver
        current_ver=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
        _info "当前版本: v${current_ver}，检查更新..."
    fi

    command -v unzip >/dev/null 2>&1 || _pkg_install unzip

    local arch xray_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  xray_arch="64" ;;
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        armv7l)        xray_arch="arm32-v7a" ;;
        armv8l)        xray_arch="arm64-v8a" ;;
        *)             xray_arch="64" ;;
    esac

    local download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip"
    local tmp_dir tmp_zip
    tmp_dir=$(mktemp -d)
    tmp_zip="${tmp_dir}/xray.zip"

    _info "下载: ${download_url}"
    
    # 带重试的下载
    local retry=0 max_retry=3
    while [ $retry -lt $max_retry ]; do
        if command -v curl >/dev/null 2>&1; then
            curl -LfsS --connect-timeout 10 --max-time 60 "$download_url" -o "$tmp_zip" 2>/dev/null && break
        else
            wget -q --timeout=60 "$download_url" -O "$tmp_zip" 2>/dev/null && break
        fi
        retry=$((retry + 1))
        _warn "重试 ${retry}/${max_retry}..."
        sleep 2
    done
    
    if [ $retry -eq $max_retry ]; then
        _error "下载失败"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! unzip -qo "$tmp_zip" -d "$tmp_dir" 2>/dev/null; then
        _error "解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi

    if [ ! -f "${tmp_dir}/xray" ]; then
        _error "二进制文件未找到"
        rm -rf "$tmp_dir"
        return 1
    fi

    mv "${tmp_dir}/xray" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    mkdir -p "$XRAY_DIR"
    
    [ -f "${tmp_dir}/geoip.dat" ] && mv -f "${tmp_dir}/geoip.dat" "$XRAY_DIR/"
    [ -f "${tmp_dir}/geosite.dat" ] && mv -f "${tmp_dir}/geosite.dat" "$XRAY_DIR/"
    
    rm -rf "$tmp_dir"

    local version
    version=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
    _success "Xray v${version} 安装成功"

    if [ "$is_first_install" = true ]; then
        _init_xray_config
        _set_ip_preference ipv4 >/dev/null 2>&1 || true
        _create_xray_service
        _manage_xray_service start
        _success "Xray已启动"
    else
        _init_xray_config
        _create_xray_service
        _manage_xray_service restart
    fi
}

# ============================================================
# 节点管理 - IP智能输出
# ============================================================

_generate_reality_keys() {
    local keypair
    keypair=$($XRAY_BIN x25519 2>&1)
    
    REALITY_PRIVATE_KEY=$(echo "$keypair" | awk 'NR==1 {print $NF}')
    REALITY_PUBLIC_KEY=$(echo "$keypair" | awk 'NR==2 {print $NF}')
    REALITY_SHORT_ID=$(openssl rand -hex 8)
    
    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
        _error "密钥生成失败: $keypair"
        return 1
    fi
}

_build_reality_stream() {
    local network="$1" sni="$2" private_key="$3" short_id="$4"
    
    jq -n \
        --arg net "$network" \
        --arg sni "$sni" \
        --arg pk "$private_key" \
        --arg sid "$short_id" \
        '{
            "network": $net,
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": ($sni + ":443"),
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
    
    jq --arg t "$tag" --arg n "$name" --arg l "$link" \
        '. + {($t): {name: $n, share_link: $l}}' \
        "$XRAY_METADATA" > "$tmp" 2>/dev/null && mv "$tmp" "$XRAY_METADATA" || {
        rm -f "$tmp"
        return 1
    }
    
    for pair in "$@"; do
        local key val
        key="${pair%%=*}"
        val="${pair#*=}"
        [ -n "$key" ] && [ -n "$val" ] || continue
        
        local tmp2="${XRAY_METADATA}.tmp.$$"
        jq --arg t "$tag" --arg k "$key" --arg v "$val" \
            '.[$t][$k] = $v' \
            "$XRAY_METADATA" > "$tmp2" 2>/dev/null && mv "$tmp2" "$XRAY_METADATA" || rm -f "$tmp2"
    done
}

_add_ss2022_reality() {
    [ ! -f "$XRAY_BIN" ] && { _error "请先安装Xray"; return 1; }
    
    # 根据IP优先级获取节点IP
    local node_ip
    node_ip=$(_get_node_ip)
    
    if [ -z "$node_ip" ]; then
        _error "无法获取服务器IP，请检查网络"
        return 1
    fi
    
    _info "使用IP: ${node_ip} (根据优先级自动选择)"
    
    read -r -p "确认使用此IP? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn] ]] && {
        read -r -p "请输入服务器IP: " node_ip
        [ -z "$node_ip" ] && { _error "IP不能为空"; return 1; }
    }

    local port
    port=$(_input_port)

    local sni="$DEFAULT_SNI"
    read -r -p "伪装域名SNI (默认: ${DEFAULT_SNI}): " custom_sni
    sni=${custom_sni:-$DEFAULT_SNI}

    local default_name="SS2022-${port}"
    read -r -p "节点名称 (默认: ${default_name}): " custom_name
    local name=${custom_name:-$default_name}

    local method="2022-blake3-aes-128-gcm"
    local password
    password=$(openssl rand -base64 16)
    
    _generate_reality_keys || return 1

    local tag="ss2022-${port}"
    local link_ip="$node_ip"
    [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local stream inbound
    stream=$(_build_reality_stream "raw" "$sni" "$REALITY_PRIVATE_KEY" "$REALITY_SHORT_ID")
    inbound=$(jq -n \
        --arg tag "$tag" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg password "$password" \
        --argjson stream "$stream" \
        '{
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

    # 生成分享链接
    local qx_link
    qx_link="shadowsocks=${link_ip}:${port}, method=${method}, password=${password}, obfs=over-tls, obfs-host=${sni}, tls-verification=true, reality-base64-pubkey=${REALITY_PUBLIC_KEY}, reality-hex-shortid=${REALITY_SHORT_ID}, udp-relay=true, tag=${name}"

    _save_xray_meta "$tag" "$name" "$qx_link" \
        "publicKey=${REALITY_PUBLIC_KEY}" \
        "shortId=${REALITY_SHORT_ID}" \
        "server=${node_ip}" \
        "sni=${sni}"

    _manage_xray_service restart
    
    _success "节点 [${name}] 添加成功"
    echo ""
    echo -e "${YELLOW}分享链接:${NC}"
    echo "${qx_link}"
    echo ""
}

_view_xray_nodes() {
    if [ ! -f "$XRAY_CONFIG" ] || \
       ! jq -e '.inbounds | length > 0' "$XRAY_CONFIG" >/dev/null 2>&1; then
        _warn "当前没有节点"
        return
    fi
    
    echo ""
    echo -e "${BOLD}══════════ Xray节点列表 ══════════${NC}"
    
    local count=0
    local tags
    tags=$(jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null)
    
    for tag in $tags; do
        count=$((count + 1))
        local port protocol name security network link
        
        protocol=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .protocol" "$XRAY_CONFIG")
        port=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .port" "$XRAY_CONFIG")
        network=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .streamSettings.network // \"raw\"" "$XRAY_CONFIG")
        security=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .streamSettings.security // \"none\"" "$XRAY_CONFIG")
        name=$(jq -r ".\"$tag\".name // \"$tag\"" "$XRAY_METADATA" 2>/dev/null)
        link=$(jq -r ".\"$tag\".share_link // empty" "$XRAY_METADATA" 2>/dev/null)
        
        echo ""
        echo -e "  ${GREEN}[${count}]${NC} ${BOLD}${name}${NC}"
        echo -e "      协议: ${YELLOW}${protocol}+${security}+${network}${NC}"
        echo -e "      端口: ${GREEN}${port}${NC}"
        [ -n "$link" ] && echo -e "      链接: ${CYAN}${link}${NC}"
    done
    echo ""
}

_delete_xray_node() {
    if [ ! -f "$XRAY_CONFIG" ] || \
       ! jq -e '.inbounds | length > 0' "$XRAY_CONFIG" >/dev/null 2>&1; then
        _warn "当前没有节点"
        return
    fi
    
    local tags
    tags=($(jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null))
    
    echo ""
    echo -e "${BOLD}══════════ 删除节点 ══════════${NC}"
    
    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local port name
        port=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .port" "$XRAY_CONFIG")
        name=$(jq -r ".\"$tag\".name // \"$tag\"" "$XRAY_METADATA" 2>/dev/null)
        echo -e "  ${GREEN}[$((i+1))]${NC} ${name} (端口: ${port})"
    done
    
    echo -e "  ${RED}[0]${NC} 取消"
    echo ""
    
    read -r -p "请选择 [0-${#tags[@]}]: " choice
    [ "$choice" = "0" ] && return
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tags[@]}" ]; then
        _error "无效选择"
        return
    fi
    
    local target_tag="${tags[$((choice-1))]}"
    local target[Unit]
Description=Xray Service (SS2022+Reality) - Zero Log Mode
Documentation=https://xtls.github.io/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
${env_lines}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=3
LimitNOFILE=65535
LimitNPROC=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${XRAY_DIR}
# 零日志配置 - 所有输出丢弃
StandardOutput=null
StandardError=null
SyslogIdentifier=xray

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable xray >/dev/null 2>&1 || true
}

_create_xray_openrc_service() {
    local mem_limit mem_limit_fmt
    mem_limit=$(_get_mem_limit)
    mem_limit_fmt=$(_format_bytes "$mem_limit")
    
    local env_exports=""
    if [ -n "$mem_limit" ] && [ "$mem_limit" != "0" ] && [ "$mem_limit" -gt 0 ]; then
        env_exports="export GOMEMLIMIT=${mem_limit}
export GOGC=${GOGC_VALUE}"
        _info "内存限制: ${mem_limit_fmt}"
        _info "GC策略: GOGC=${GOGC_VALUE}"
    fi
    
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service (SS2022+Reality) - Zero Log Mode"
command="${XRAY_BIN}"
command_args="run -c ${XRAY_CONFIG}"
command_background=true
pidfile="${XRAY_PID_FILE}"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=3
respawn_period=60

# 环境变量 - 内存优化
${env_exports}

depend() {
    need net
    after firewall dns
}

start_pre() {
    checkpath -d -m 0755 -o root:root "${XRAY_DIR}" 2>/dev/null || true
}
EOF
    
    chmod +x /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
}

_create_xray_service() {
    case "$INIT_SYSTEM" in
        systemd) _create_xray_systemd_service ;;
        openrc)  _create_xray_openrc_service ;;
        *) _warn "未检测到服务管理器" ;;
    esac
}

_manage_xray_service() {
    local action="$1"
    
    case "$INIT_SYSTEM" in
        systemd)
            if [ "$action" = "status" ]; then
                systemctl status xray --no-pager 2>/dev/null || true
                return
            fi
            
            if systemctl "$action" xray >/dev/null 2>&1; then
                case "$action" in
                    start) _success "Xray已启动" ;;
                    stop) _success "Xray已停止" ;;
                    restart) _success "Xray已重启" ;;
                esac
            else
                _error "Xray ${action}失败"
                return 1
            fi
            ;;
        openrc)
            if [ "$action" = "status" ]; then
                rc-service xray status 2>/dev/null || true
                return
            fi
            
            if rc-service xray "$action" >/dev/null 2>&1; then
                case "$action" in
                    start) _success "Xray已启动" ;;
                    stop) _success "Xray已停止" ;;
                    restart) _success "Xray已重启" ;;
                esac
            else
                _error "Xray ${action}失败"
                return 1
            fi
            ;;
        *)
            _warn "未检测到服务管理器"
            ;;
    esac
}

_view_xray_log() {
    _warn "当前为零日志模式，无日志可查看"
    _info "如需查看日志，请修改配置文件: ${XRAY_CONFIG}"
    _info "将 loglevel 从 \"none\" 改为 \"warning\" 或 \"info\""
}

# ============================================================
# Xray核心管理
# ============================================================

_install_or_update_xray() {
    local is_first_install=false
    [ ! -f "$XRAY_BIN" ] && is_first_install=true

    if [ "$is_first_install" = true ]; then
        _info "首次安装Xray..."
    else
        local current_ver
        current_ver=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
        _info "当前版本: v${current_ver}，检查更新..."
    fi

    command -v unzip >/dev/null 2>&1 || _pkg_install unzip

    local arch xray_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  xray_arch="64" ;;
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        armv7l)        xray_arch="arm32-v7a" ;;
        armv8l)        xray_arch="arm64-v8a" ;;
        *)             xray_arch="64" ;;
    esac

    local download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip"
    local tmp_dir tmp_zip
    tmp_dir=$(mktemp -d)
    tmp_zip="${tmp_dir}/xray.zip"

    _info "下载: ${download_url}"
    
    # 带重试的下载
    local retry=0 max_retry=3
    while [ $retry -lt $max_retry ]; do
        if command -v curl >/dev/null 2>&1; then
            curl -LfsS --connect-timeout 10 --max-time 60 "$download_url" -o "$tmp_zip" 2>/dev/null && break
        else
            wget -q --timeout=60 "$download_url" -O "$tmp_zip" 2>/dev/null && break
        fi
        retry=$((retry + 1))
        _warn "重试 ${retry}/${max_retry}..."
        sleep 2
    done
    
    if [ $retry -eq $max_retry ]; then
        _error "下载失败"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! unzip -qo "$tmp_zip" -d "$tmp_dir" 2>/dev/null; then
        _error "解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi

    if [ ! -f "${tmp_dir}/xray" ]; then
        _error "二进制文件未找到"
        rm -rf "$tmp_dir"
        return 1
    fi

    mv "${tmp_dir}/xray" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    mkdir -p "$XRAY_DIR"
    
    [ -f "${tmp_dir}/geoip.dat" ] && mv -f "${tmp_dir}/geoip.dat" "$XRAY_DIR/"
    [ -f "${tmp_dir}/geosite.dat" ] && mv -f "${tmp_dir}/geosite.dat" "$XRAY_DIR/"
    
    rm -rf "$tmp_dir"

    local version
    version=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
    _success "Xray v${version} 安装成功"

    if [ "$is_first_install" = true ]; then
        _init_xray_config
        _set_ip_preference ipv4 >/dev/null 2>&1 || true
        _create_xray_service
        _manage_xray_service start
        _success "Xray已启动"
    else
        _init_xray_config
        _create_xray_service
        _manage_xray_service restart
    fi
}

# ============================================================
# 节点管理 - IP智能输出
# ============================================================

_generate_reality_keys() {
    local keypair
    keypair=$($XRAY_BIN x25519 2>&1)
    
    REALITY_PRIVATE_KEY=$(echo "$keypair" | awk 'NR==1 {print $NF}')
    REALITY_PUBLIC_KEY=$(echo "$keypair" | awk 'NR==2 {print $NF}')
    REALITY_SHORT_ID=$(openssl rand -hex 8)
    
    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
        _error "密钥生成失败: $keypair"
        return 1
    fi
}

_build_reality_stream() {
    local network="$1" sni="$2" private_key="$3" short_id="$4"
    
    jq -n \
        --arg net "$network" \
        --arg sni "$sni" \
        --arg pk "$private_key" \
        --arg sid "$short_id" \
        '{
            "network": $net,
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": ($sni + ":443"),
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
    
    jq --arg t "$tag" --arg n "$name" --arg l "$link" \
        '. + {($t): {name: $n, share_link: $l}}' \
        "$XRAY_METADATA" > "$tmp" 2>/dev/null && mv "$tmp" "$XRAY_METADATA" || {
        rm -f "$tmp"
        return 1
    }
    
    for pair in "$@"; do
        local key val
        key="${pair%%=*}"
        val="${pair#*=}"
        [ -n "$key" ] && [ -n "$val" ] || continue
        
        local tmp2="${XRAY_METADATA}.tmp.$$"
        jq --arg t "$tag" --arg k "$key" --arg v "$val" \
            '.[$t][$k] = $v' \
            "$XRAY_METADATA" > "$tmp2" 2>/dev/null && mv "$tmp2" "$XRAY_METADATA" || rm -f "$tmp2"
    done
}

_add_ss2022_reality() {
    [ ! -f "$XRAY_BIN" ] && { _error "请先安装Xray"; return 1; }
    
    # 根据IP优先级获取节点IP
    local node_ip
    node_ip=$(_get_node_ip)
    
    if [ -z "$node_ip" ]; then
        _error "无法获取服务器IP，请检查网络"
        return 1
    fi
    
    _info "使用IP: ${node_ip} (根据优先级自动选择)"
    
    read -r -p "确认使用此IP? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn] ]] && {
        read -r -p "请输入服务器IP: " node_ip
        [ -z "$node_ip" ] && { _error "IP不能为空"; return 1; }
    }

    local port
    port=$(_input_port)

    local sni="$DEFAULT_SNI"
    read -r -p "伪装域名SNI (默认: ${DEFAULT_SNI}): " custom_sni
    sni=${custom_sni:-$DEFAULT_SNI}

    local default_name="SS2022-${port}"
    read -r -p "节点名称 (默认: ${default_name}): " custom_name
    local name=${custom_name:-$default_name}

    local method="2022-blake3-aes-128-gcm"
    local password
    password=$(openssl rand -base64 16)
    
    _generate_reality_keys || return 1

    local tag="ss2022-${port}"
    local link_ip="$node_ip"
    [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local stream inbound
    stream=$(_build_reality_stream "raw" "$sni" "$REALITY_PRIVATE_KEY" "$REALITY_SHORT_ID")
    inbound=$(jq -n \
        --arg tag "$tag" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg password "$password" \
        --argjson stream "$stream" \
        '{
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

    # 生成分享链接
    local qx_link
    qx_link="shadowsocks=${link_ip}:${port}, method=${method}, password=${password}, obfs=over-tls, obfs-host=${sni}, tls-verification=true, reality-base64-pubkey=${REALITY_PUBLIC_KEY}, reality-hex-shortid=${REALITY_SHORT_ID}, udp-relay=true, tag=${name}"

    _save_xray_meta "$tag" "$name" "$qx_link" \
        "publicKey=${REALITY_PUBLIC_KEY}" \
        "shortId=${REALITY_SHORT_ID}" \
        "server=${node_ip}" \
        "sni=${sni}"

    _manage_xray_service restart
    
    _success "节点 [${name}] 添加成功"
    echo ""
    echo -e "${YELLOW}分享链接:${NC}"
    echo "${qx_link}"
    echo ""
}

_view_xray_nodes() {
    if [ ! -f "$XRAY_CONFIG" ] || \
       ! jq -e '.inbounds | length > 0' "$XRAY_CONFIG" >/dev/null 2>&1; then
        _warn "当前没有节点"
        return
    fi
    
    echo ""
    echo -e "${BOLD}══════════ Xray节点列表 ══════════${NC}"
    
    local count=0
    local tags
    tags=$(jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null)
    
    for tag in $tags; do
        count=$((count + 1))
        local port protocol name security network link
        
        protocol=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .protocol" "$XRAY_CONFIG")
        port=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .port" "$XRAY_CONFIG")
        network=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .streamSettings.network // \"raw\"" "$XRAY_CONFIG")
        security=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .streamSettings.security // \"none\"" "$XRAY_CONFIG")
        name=$(jq -r ".\"$tag\".name // \"$tag\"" "$XRAY_METADATA" 2>/dev/null)
        link=$(jq -r ".\"$tag\".share_link // empty" "$XRAY_METADATA" 2>/dev/null)
        
        echo ""
        echo -e "  ${GREEN}[${count}]${NC} ${BOLD}${name}${NC}"
        echo -e "      协议: ${YELLOW}${protocol}+${security}+${network}${NC}"
        echo -e "      端口: ${GREEN}${port}${NC}"
        [ -n "$link" ] && echo -e "      链接: ${CYAN}${link}${NC}"
    done
    echo ""
}

_delete_xray_node() {
    if [ ! -f "$XRAY_CONFIG" ] || \
       ! jq -e '.inbounds | length > 0' "$XRAY_CONFIG" >/dev/null 2>&1; then
        _warn "当前没有节点"
        return
    fi
    
    local tags
    tags=($(jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null))
    
    echo ""
    echo -e "${BOLD}══════════ 删除节点 ══════════${NC}"
    
    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local port name
        port=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .port" "$XRAY_CONFIG")
        name=$(jq -r ".\"$tag\".name // \"$tag\"" "$XRAY_METADATA" 2>/dev/null)
        echo -e "  ${GREEN}[$((i+1))]${NC} ${name} (端口: ${port})"
    done
    
    echo -e "  ${RED}[0]${NC} 取消"
    echo ""
    
    read -r -p "请选择 [0-${#tags[@]}]: " choice
    [ "$choice" = "0" ] && return
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tags[@]}" ]; then
        _error "无效选择"
        return
    fi
    
    local target_tag="${tags[$((choice-1))]}"
    local target_name
    target_name=$(jq -r ".\"$target_tag\".name // \"$target_tag\"" "$XRAY_METADATA" 2>/dev/null)
    
    read -r -p "确定删除 [${target_name}]? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { _info "已取消"; return; }
    
    _atomic_modify_json "$XRAY_CONFIG" "del(.inbounds[] | select(.tag == \"$target_tag\"))" || return 1
    _atomic_modify_json "$XRAY_METADATA" "del(.\"$target_tag\")" >/dev/null 2>&1 || true
    
    _manage_xray_service restart
    _success "节点 [${target_name}] 已删除"
}

_modify_xray_port() {
    if [ ! -f "$XRAY_CONFIG" ] || \
       ! jq -e '.inbounds | length > 0' "$XRAY_CONFIG" >/dev/null 2>&1; then
        _warn "当前没有节点"
        return
    fi
    
    local tags
    tags=($(jq -r '.inbounds[].tag' "$XRAY_CONFIG" 2>/dev/null))
    
    echo ""
    echo -e "${BOLD}══════════ 修改端口 ══════════${NC}"
    
    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local port name
        port=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .port" "$XRAY_CONFIG")
        name=$(jq -r ".\"$tag\".name // \"$tag\"" "$XRAY_METADATA" 2>/dev/null)
        echo -e "  ${GREEN}[$((i+1))]${NC} ${name} (端口: ${port})"
    done
    
    echo -e "  ${RED}[0]${NC} 取消"
    echo ""
    
    read -r -p "请选择 [0-${#tags[@]}]: " choice
    [ "$choice" = "0" ] && return
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tags[@]}" ]; then
        _error "无效选择"
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
    jq --arg ot "$target_tag" --arg nt "$new_tag" --arg n "$new_name" --arg l "$new_link" \
        '. + {($nt): (.[$ot] + {name: $n, share_link: $l})} | del(.[$ot])' \
        "$XRAY_METADATA" > "$tmp" 2>/dev/null && mv "$tmp" "$XRAY_METADATA" || rm -f "$tmp"
    
    _manage_xray_service restart
    _success "端口已改为 ${new_port}"
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
    
    rm -f "$XRAY_BIN" "$XRAY_PID_FILE"
    rm -rf "$XRAY_DIR"
}

_uninstall_xray() {
    echo ""
    _warn "即将卸载Xray核心及配置"
    read -r -p "确定卸载? (输入 yes 确认): " confirm
    [ "$confirm" = "yes" ] || { _info "已取消"; return; }
    
    _remove_xray_runtime
    _success "Xray已卸载"
}

_uninstall_script() {
    _warn "即将完全卸载并删除脚本"
    
    read -r -p "确定执行? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && _info "已取消" && return

    _remove_xray_runtime
    
    rm -f "$SCRIPT_INSTALL_PATH" "$SCRIPT_ALIAS_PATH"
    [ -n "$SELF_SCRIPT_PATH" ] && [ -f "$SELF_SCRIPT_PATH" ] && \
       [ "$SELF_SCRIPT_PATH" != "$SCRIPT_INSTALL_PATH" ] && rm -f "$SELF_SCRIPT_PATH"

    _success "卸载完成"
    exit 0
}

_show_status_header() {
    local xray_status="${RED}未安装${NC}"
    local xray_ver=""
    
    if [ -f "$XRAY_BIN" ]; then
        xray_ver=$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')
        
        case "$INIT_SYSTEM" in
            systemd)
                systemctl is-active xray >/dev/null 2>&1 && \
                    xray_status="${GREEN}● 运行中${NC}" || xray_status="${YELLOW}○ 已停止${NC}"
                ;;
            openrc)
                rc-service xray status >/dev/null 2>&1 && \
                    xray_status="${GREEN}● 运行中${NC}" || xray_status="${YELLOW}○ 已停止${NC}"
                ;;
            *)
                xray_status="${YELLOW}○ 未知${NC}"
                ;;
        esac
    fi
    
    local node_count
    node_count=$(jq '.inbounds | length' "$XRAY_CONFIG" 2>/dev/null || echo 0)
    
    local current_ip_pref
    current_ip_pref=$(_get_ip_preference)
    [ "$current_ip_pref" = "ipv6" ] && current_ip_pref="IPv6" || current_ip_pref="IPv4"
    
    echo -e "=================================================="
    echo -e " ${BOLD}Xray 极致优化版 v${SCRIPT_VERSION}${NC}"
    echo -e " 零日志 | 智能IP | 内存优化"
    echo -e "=================================================="
    
    if [ -n "$xray_ver" ]; then
        echo -e " Xray v${xray_ver}: ${xray_status} (${node_count}节点)"
    else
        echo -e " Xray: ${xray_status} (${node_count}节点)"
    fi
    
    echo -e " IP优先级: ${CYAN}${current_ip_pref} 优先${NC}"
    
    # 内存信息
    if [ -f "$XRAY_BIN" ]; then
        local mem_limit
        mem_limit=$(_get_mem_limit)
        if [ -n "$mem_limit" ] && [ "$mem_limit" != "0" ]; then
            local mem_fmt
            mem_fmt=$(_format_bytes "$mem_limit")
            echo -e " 内存限制: ${GREEN}${mem_fmt}${NC} (GOGC=${GOGC_VALUE})"
        fi
    fi
    
    echo -e "--------------------------------------------------"
}

_xray_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        _show_status_header
        
        echo -e " ${CYAN}【服务控制】${NC}"
        _menu_item 1  "安装/更新 Xray"
        _menu_item 2  "启动 Xray"
        _menu_item 3  "停止 Xray"
        _menu_item 4  "重启 Xray"
        _menu_item 5  "查看状态"
        _menu_item 6  "查看日志 (当前禁用)"
        echo ""
        echo -e " ${CYAN}【节点管理】${NC}"
        _menu_item 7  "添加 SS2022+Reality 节点"
        _menu_item 8  "查看所有节点"
        _menu_item 9  "删除节点"
        _menu_item 10 "修改节点端口"
        echo ""
        echo -e " ${CYAN}【系统设置】${NC}"
        _menu_item 11 "更新脚本"
        _menu_item 12 "设置IP优先级 (IPv4/IPv6)"
        echo ""
        _menu_danger 88 "卸载 Xray"
        _menu_danger 99 "完全卸载 (含脚本)"
        _menu_exit 0 "退出"
        echo -e "=================================================="
        
        read -r -p "请选择 [0-99]: " choice
        case "$choice" in
            1) _install_or_update_xray; _pause ;;
            2) [ -f "$XRAY_BIN" ] && _manage_xray_service start; _pause ;;
            3) [ -f "$XRAY_BIN" ] && _manage_xray_service stop; _pause ;;
            4) [ -f "$XRAY_BIN" ] && _manage_xray_service restart; _pause ;;
            5) [ -f "$XRAY_BIN" ] && _manage_xray_service status; _pause ;;
            6) _view_xray_log; _pause ;;
            7) _init_xray_config; _add_ss2022_reality; _pause ;;
            8) _view_xray_nodes; _pause ;;
            9) _delete_xray_node; _pause ;;
            10) _modify_xray_port; _pause ;;
            11) _update_script_self; _pause; exit 0 ;;
            12) _choose_ip_preference ;;
            88) _uninstall_xray; _pause ;;
            99) _uninstall_script ;;
            0) exit 0 ;;
            *) _error "无效输入"; _pause ;;
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

# 清理临时文件
trap 'rm -f "${XRAY_DIR}"/*.tmp.* 2>/dev/null || true' EXIT

_main "$@"
