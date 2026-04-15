# Xray SS2022 + Reality 一键管理脚本

<div align="center">

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-blue.svg)]()
[![Protocol](https://img.shields.io/badge/protocol-SS2022%2BReality-orange.svg)]()
[![Init](https://img.shields.io/badge/init-systemd%20%7C%20openrc-purple.svg)]()

**基于 [大表哥 singbox-lite](https://github.com/0xdabiaoge/singbox-lite) 脚本二次开发**

</div>

## ✨ 功能特性

- 🔐 **SS2022 + Reality 协议** - 新一代安全代理协议，抗封锁能力强
- 🐧 **多发行版支持** - 支持 Alpine (OpenRC)、Debian/Ubuntu (systemd)、CentOS/Rocky/Fedora (systemd) 等
- 🌐 **双栈 IP 支持** - 支持 IPv4/IPv6 优先级设置，自动检测公网 IP
- 🛠️ **完整节点管理** - 添加、删除、修改端口、查看节点信息
- 📱 **Quantumult X 配置** - 自动生成 Quantumult X 兼容配置格式
- 🔄 **脚本自更新** - 一键更新脚本到最新版本
- 🧹 **完整卸载** - 支持保留配置卸载或完全清理（包括脚本自毁）

## 📋 系统要求

| 项目 | 要求 |
|------|------|
| **操作系统** | Alpine / Debian / Ubuntu / CentOS / Rocky / Fedora 等 Linux 发行版 |
| **包管理器** | `apk` / `apt-get` / `yum` / `dnf` 任一即可 |
| **初始化系统** | systemd 或 OpenRC |
| **架构** | x86_64 / AMD64 / ARM64 / ARMv7 |
| **权限** | Root 用户权限 |
| **网络** | 可访问 GitHub 以下载 Xray 核心 |

## 🚀 快速开始

### 一键安装脚本

```bash
curl -fsSL https://raw.githubusercontent.com/Ezrea7/SS2022-Reality/refs/heads/main/xray.sh -o /usr/local/bin/SS2022 && chmod +x /usr/local/bin/SS2022 && /usr/local/bin/SS2022
```
## 快捷指令

### 安装完成后，使用以下命令进入管理菜单：
```
ss2022
```

# Quanumult X配置示例

### 脚本自动生成如下格式配置
```
shadowsocks=服务器IP:端口, method=2022-blake3-aes-128-gcm, 
password=密码, obfs=over-tls, obfs-host=伪装域名, 
tls-verification=true, reality-base64-pubkey=公钥, 
reality-hex-shortid=短ID, udp-relay=true, 
 tag=节点名称
```
# 如果环境不支持UDP、可在节点名称前加入下面内容、使其UDP流量封装进TCP、
```
udp-over-tcp=sp.v2,
```
### 推荐客户端：Quantumult X
#### 如需配置其他客户端请查看脚本内Json配置文件

## 使用说明

### 🖥️ 管理菜单说明

| 选项 | 功能 | 说明 |
|:----:|------|------|
| 1 | 安装/更新 Xray 内核 | 自动下载并安装最新版 Xray-core |
| 2 | 启动 Xray | 启动服务 |
| 3 | 停止 Xray | 停止服务 |
| 4 | 重启 Xray | 重启服务 |
| 5 | 添加 SS2022+Reality 节点 | 创建新节点 |
| 6 | 查看所有节点 | 显示节点信息及 Quantumult X 配置 |
| 7 | 删除节点 | 删除指定节点 |
| 8 | 修改节点端口 | 修改已存在节点的监听端口 |
| 9 | 更新脚本 | 从 GitHub 更新脚本 |
| 10 | 设置网络优先级 | 设置 IPv4 / IPv6 优先 |
| 88 | 卸载 Xray | 卸载 Xray 核心与配置 |
| 99 | 卸载脚本 | 完整清理脚本及相关文件 |

## 配置文件

### 核心配置文件
```
/usr/local/etc/xray/config.json
```

### 节点源数据
```
/usr/local/etc/xray/metadata.json
```

### IP优先级配置
```
/usr/local/etc/xray/ip_preference.conf
```
## 更新日志

### v0.0.8

- 默认 log 改为完全关闭
- outbounds 精简为仅保留 freedom
- 删除空的 routing.rules
- 删除 XRAY_LOG 相关冗余逻辑
- 移除脚本内内存限制逻辑，交由 Xray 自行控制
- 默认 SNI 改为 support.apple.com 
---

## License

MIT License