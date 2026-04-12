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
- ⚡ **智能内存管理** - 容器环境自动识别，智能计算内存限制
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

## 🚀 快速开始

### 一键安装脚本

```bash
(curl -LfsS https://raw.githubusercontent.com/Ezrea7/SS2022-Reality/refs/heads/main/xray.sh -o /usr/local/bin/SS2022 || wget -q https://raw.githubusercontent.com/Ezrea7/SS2022-Reality/refs/heads/main/xray.sh -O /usr/local/bin/SS2022) && chmod +x /usr/local/bin/SS2022 && SS2022
