# Xray xTLS + Reality 一键管理脚本

<div align="center">

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-blue.svg)]()
[![Protocol](https://img.shields.io/badge/protocol-SS2022%2BReality-orange.svg)]()
[![Init](https://img.shields.io/badge/init-systemd%20%7C%20openrc-purple.svg)]()

**基于 [大表哥 singbox-lite](https://github.com/0xdabiaoge/singbox-lite) 脚本二次开发**

</div>

## ✨ 功能特性

- 🔐 **支持Vless+Reality Anytls+Reality SS2022 + Reality TroJan +Reality Vmess +Reality 协议** - 新一代安全代理协议，抗封锁能力强
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
curl -fsSL https://raw.githubusercontent.com/Ezrea7/xTLS-Reality/refs/heads/main/xray.sh -o /usr/local/bin/xtls && chmod +x /usr/local/bin/xtls && /usr/local/bin/xtls
```
## 快捷指令

### 安装完成后，使用以下命令进入管理菜单：
```
xtls
```

# Quanumult X  SS2022+Reality配置示例

### 脚本自动生成如下格式配置
```
shadowsocks=服务器IP:端口, method=2022-blake3-aes-128-gcm, 
password=密码, obfs=over-tls, obfs-host=伪装域名, 
tls-verification=true, reality-base64-pubkey=公钥, 
reality-hex-shortid=短ID, udp-relay=true, 
udp-over-tcp=sp.v2, tag=节点名称
```

### 推荐客户端：Quantumult X
#### 如需配置其他客户端请查看脚本内Json配置文件


## 配置文件

### 核心配置文件
```
/usr/local/etc/xray/config.json
```

### 节点源数据
```
/usr/local/etc/xtls/metadata.json
```

### IP优先级配置
```
/usr/local/etc/xray/ip_preference.conf
```
## 更新日志

#### 4.17 vless+Vision+ReaLity协议支持标准分享链接
#### 4.16 加入对singbox内核的支持 及anytls+reality协议支持 
---

## License

MIT License
