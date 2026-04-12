#!/bin/bash

# ============================================================
#      Xray SS2022 + Reality 独立安装管理脚本 (单协议版) - 优化版
# ============================================================

SCRIPT_VERSION="3.5.1"
SCRIPT_CMD_NAME="ss2022"
SCRIPT_CMD_ALIAS="SS2022"
SCRIPT_INSTALL_PATH="/usr/local/bin/${SCRIPT_CMD_NAME}"
SCRIPT_ALIAS_PATH="/usr/local/bin/${SCRIPT_CMD_ALIAS}"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/Ezrea7/SS2022-Reality/refs/heads/main/xray.sh"
SELF_SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ========================== 系统检测 ==========================
check_dependencies() {
    command -v curl >/dev/null 2>&1 || apt-get update && apt-get install -y curl
    command -v jq >/dev/null 2>&1 || apt-get update && apt-get install -y jq
    command -v tar >/dev/null 2>&1 || apt-get update && apt-get install -y tar
}

# ========================== IP 自动探测 ==========================
detect_ip() {
    local ip
    if [[ "$IPV6_PRIORITY" == "true" ]]; then
        ip=$(curl -6 -s https://api64.ipify.org || curl -4 -s https://api.ipify.org)
    else
        ip=$(curl -4 -s https://api.ipify.org || curl -6 -s https://api64.ipify.org)
    fi
    echo "$ip"
}

# ========================== 安装 / 更新 ==========================
install_xray() {
    echo "[信息] 正在下载 Xray SS2022 + Reality 核心..."
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    curl -L -s "$url" -o /tmp/xray.zip || wget -q "$url" -O /tmp/xray.zip
    unzip -o /tmp/xray.zip -d /tmp/xray && mv /tmp/xray/xray "$SCRIPT_INSTALL_PATH" && chmod +x "$SCRIPT_INSTALL_PATH"
    rm -rf /tmp/xray /tmp/xray.zip
}

# ========================== JSON 配置 ==========================
generate_config() {
    local ip addr
    ip=$(detect_ip)
    addr="0.0.0.0"
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "YOUR_PASSWORD",
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": "$ip",
          "dest": "$addr:443",
          "xver": 0
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
}

# ========================== 启动服务 ==========================
start_service() {
    export GOMEMLIMIT="128MB"
    "$SCRIPT_INSTALL_PATH" -config /usr/local/etc/xray/config.json &>/dev/null &
    echo "[信息] Xray 服务已启动"
}

# ========================== 主逻辑 ==========================
main() {
    check_dependencies
    install_xray
    generate_config
    start_service
    echo "[信息] 安装完成，配置已生效"
}

main "$@"

