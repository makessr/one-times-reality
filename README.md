# one-times-reality

基于 sing-box 的一键安装脚本，支持 **VLESS + Reality**、**TUIC v5**、**Hysteria2** 三协议。

## 快速开始

```bash
# TCP + Reality
bash <(curl -fsSL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh) install

# TUIC v5（UDP，自签证书）
bash <(curl -fsSL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh) install-tuic

# Hysteria2（UDP，自签证书 + salamander 混淆）
bash <(curl -fsSL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh) install-hy2

# 三协议同开
bash <(curl -fsSL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh) install-all
```

## 所有命令

| 命令 | 说明 |
|---|---|
| `install` | 安装 VLESS + Reality（TCP） |
| `install-tuic` | 安装 TUIC v5（UDP，自签证书） |
| `install-hy2` | 安装 Hysteria2（UDP，自签证书 + salamander 混淆） |
| `install-all` | 三协议同时安装 |
| `add-tuic` | 在已有安装上追加 TUIC v5 |
| `add-hy2` | 在已有安装上追加 Hysteria2 |
| `uninstall` | 卸载 sing-box |
| `restart` | 重启服务 |
| `status` | 查看服务状态与端口 |
| `config` | 查看配置与客户端链接 |

## 端口分配

```
VLESS + Reality → 10000-19999 (TCP)
TUIC v5         → 20000-29999 (UDP)
Hysteria2       → 30000-39999 (UDP)
```

## 细节说明

- **VLESS + Reality**：使用 `gateway.icloud.com` 作为 SNI，无需证书，伪装正常 TLS 流量
- **TUIC v5 / Hysteria2**：使用自签名 EC 证书（`/etc/sing-box/server.{crt,key}`），客户端需关闭证书验证
- 安装过程自动启用 BBR 拥塞控制
- 所有协议共用同一个 sing-box 实例和 systemd 服务

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh) uninstall
```

## 追加协议到已有安装

如果机器上已经装了某个协议，想加别的而不影响现有配置：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh) add-tuic
bash <(curl -fsSL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh) add-hy2
```

## 本地使用

```bash
curl -sL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh -o reality.sh
chmod +x reality.sh
./reality.sh install-all
```
