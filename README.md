# one-times-reality

基于 sing-box 的一键安装与管理脚本，支持 **VLESS + Reality**、**TUIC v5**、**Hysteria2** 三协议，提供智能检测的交互菜单。

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh)
```

无参数运行自动进入 **交互管理菜单**，智能检测当前已安装的协议，可视化选择操作。

## 交互菜单

```bash
╔═══════════════════════════════════════════╗
║         Sing-Box 管理面板                 ║
╠═══════════════════════════════════════════╣
║  服务: ✅ 运行中
║
║  1.  VLESS + Reality    ✅   端口 10432
║  2.  TUIC v5            ❌
║  3.  Hysteria2          ✅   端口 30123
║
║  4. 安装全部缺失协议
║  5. 查看配置与链接
║  6. 重启服务
║  7. 卸载 sing-box
║  0. 退出
╚═══════════════════════════════════════════╝
```

- 已安装的协议显示 ✅ 和端口号，点选可查看链接
- 未安装的协议点选自动安装（追加到已有配置，不覆盖其他协议）
- 选项 4 自动检测缺失项一并补齐

## 端口分配

```
VLESS + Reality → 10000-19999 (TCP)
TUIC v5         → 20000-29999 (UDP)
Hysteria2       → 30000-39999 (UDP)
```

> TUIC v5 / Hysteria2 使用自签名 EC 证书（`/etc/sing-box/server.{crt,key}`），客户端需关闭证书验证。

## 全部命令

| 命令 | 说明 |
|---|---|
| 无参数 / `menu` | 交互管理菜单（智能检测） |
| `install` | 安装 VLESS + Reality |
| `install-tuic` | 安装 TUIC v5（自签证书） |
| `install-hy2` | 安装 Hysteria2（自签证书 + salamander 混淆） |
| `install-all` | 三协议同时安装 |
| `install-missing` | 只安装缺失的协议 |
| `add-vless` | 追加 VLESS + Reality 到已有安装 |
| `add-tuic` | 追加 TUIC v5 到已有安装 |
| `add-hy2` | 追加 Hysteria2 到已有安装 |
| `uninstall` | 卸载 sing-box |
| `restart` | 重启服务 |
| `status` | 查看服务状态与端口 |
| `config` | 查看配置与客户端链接 |

## 细节

- **VLESS + Reality**：使用 `gateway.icloud.com` 作为 SNI，无需证书
- **TUIC v5 / Hysteria2**：自签名 EC 证书，salamander 混淆（仅 hy2）
- 自动启用 BBR 拥塞控制
- 所有协议共用同一个 sing-box 实例
- `add-*` 命令追加协议到现有配置，不影响已有协议
- 安装过程自动生成所有随机参数（UUID / 密码 / 端口 / 密钥对）

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh) uninstall
```

## 本地使用

```bash
curl -sL https://raw.githubusercontent.com/makessr/one-times-reality/main/reality.sh -o reality.sh
chmod +x reality.sh
./reality.sh
```
