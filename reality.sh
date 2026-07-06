#!/bin/bash
set -e

SERVICE_NAME="sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_FILE="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERR]${NC} $1"; }

# ──────────────────────────────────────────────
# BBR 启用
# ──────────────────────────────────────────────
function enable_bbr() {
    info "启用 BBR 拥塞控制..."
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    AVAIL_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    if [ "$CUR_CC" = "bbr" ] || echo "$AVAIL_CC" | grep -qw bbr; then
        info "BBR 已启用（当前拥塞控制: ${CUR_CC:-unknown}）"
    else
        warn "未检测到 BBR，可用拥塞控制: ${AVAIL_CC}"
    fi
}

# ──────────────────────────────────────────────
# 生成自签名证书（用于 tuic）
# ──────────────────────────────────────────────
function gen_self_signed_cert() {
    local CERT_DIR="$1"
    mkdir -p "$CERT_DIR"
    if [ ! -f "$CERT_DIR/tuic.crt" ] || [ ! -f "$CERT_DIR/tuic.key" ]; then
        info "生成自签名证书..."
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 3650 -keyout "$CERT_DIR/tuic.key" -out "$CERT_DIR/tuic.crt" \
            -subj "/CN=salanghe.com" -addext "subjectAltName=DNS:salanghe.com"
        info "证书已生成: $CERT_DIR/tuic.crt"
    else
        info "证书已存在，跳过生成"
    fi
}

# ──────────────────────────────────────────────
# 下载安装 sing-box（共用）
# ──────────────────────────────────────────────
function download_singbox() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请用 root 权限运行此脚本"
        exit 1
    fi

    enable_bbr

    apt-get update -y
    apt-get install -y curl unzip jq openssl tar

    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    VERSION=${LATEST_VERSION#v}
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64)   SB_ARCH="amd64" ;;
        aarch64)  SB_ARCH="arm64" ;;
        armv7l)   SB_ARCH="armv7" ;;
        *) err "不支持的架构: $ARCH"; exit 1 ;;
    esac

    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    info "下载 sing-box: $URL"
    curl -L -o /tmp/singbox.tar.gz "$URL"
    mkdir -p /tmp/singbox
    tar -xzf /tmp/singbox.tar.gz -C /tmp/singbox

    if [ -f "/tmp/singbox/sing-box" ]; then
        SRC="/tmp/singbox/sing-box"
    elif [ -f "/tmp/singbox/sing-box-${VERSION}-linux-${SB_ARCH}/sing-box" ]; then
        SRC="/tmp/singbox/sing-box-${VERSION}-linux-${SB_ARCH}/sing-box"
    else
        SRC="$(find /tmp/singbox -type f -name 'sing-box' | head -n1)"
    fi

    if [ -z "$SRC" ]; then
        err "解压后未找到 sing-box 可执行文件"
        exit 1
    fi

    mv "$SRC" "$BIN_FILE"
    chmod +x "$BIN_FILE"
    info "sing-box 已安装: $BIN_FILE"
}

# ──────────────────────────────────────────────
# 写入 systemd 服务
# ──────────────────────────────────────────────
function setup_systemd() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-Box Service
After=network.target

[Service]
ExecStart=$BIN_FILE run -c $CONFIG_FILE
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    sleep 3

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "服务启动失败！查看日志："
        journalctl -u "$SERVICE_NAME" --no-pager -n 20
        exit 1
    fi
    info "sing-box 服务运行中"
}

# ──────────────────────────────────────────────
# 清理临时文件
# ──────────────────────────────────────────────
function clean_temp() {
    rm -rf /tmp/singbox*
}

# ──────────────────────────────────────────────
# VLESS + Reality 安装
# ──────────────────────────────────────────────
function install_singbox() {
    download_singbox

    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$($BIN_FILE generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    PORT=$((RANDOM % 10000 + 10000))
    SNI="gateway.icloud.com"
    SHORT_ID=$(openssl rand -hex 4)

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

    info "验证配置文件..."
    if ! $BIN_FILE check -c "$CONFIG_FILE"; then
        err "配置文件验证失败！"
        exit 1
    fi

    setup_systemd

    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    VLESS_URL="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=ios&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"

    echo ""
    info "======================"
    info "Sing-Box Reality 安装完成 ✅"
    info "服务状态: $(systemctl is-active $SERVICE_NAME)"
    info "监听端口: $PORT"
    echo ""
    info "客户端链接："
    echo "${VLESS_URL}"
    echo ""
    info "管理命令："
    info "启动: systemctl start $SERVICE_NAME"
    info "停止: systemctl stop $SERVICE_NAME"
    info "状态: systemctl status $SERVICE_NAME"
    info "日志: journalctl -u $SERVICE_NAME -f"
    info "======================"

    clean_temp
}

# ──────────────────────────────────────────────
# TUIC v5 安装
# ──────────────────────────────────────────────
function install_tuic() {
    download_singbox

    UUID=$(cat /proc/sys/kernel/random/uuid)
    TUIC_PASS=$(openssl rand -base64 16 | tr -d '=+/')
    PORT=$((RANDOM % 10000 + 20000))  # 20000-30000
    SNI="salanghe.com"

    mkdir -p "$CONFIG_DIR"
    gen_self_signed_cert "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "password": "${TUIC_PASS}"
        }
      ],
      "congestion_control": "bbr",
      "udp_relay_mode": "native",
      "zero_rtt_handshake": false,
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "alpn": ["h3"],
        "certificate_path": "${CONFIG_DIR}/tuic.crt",
        "key_path": "${CONFIG_DIR}/tuic.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

    info "验证配置文件..."
    if ! $BIN_FILE check -c "$CONFIG_FILE"; then
        err "配置文件验证失败！"
        exit 1
    fi

    setup_systemd

    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    TUIC_URL="tuic://${UUID}:${TUIC_PASS}@${SERVER_IP}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI}#TUIC"

    echo ""
    info "======================"
    info "Sing-Box TUIC v5 安装完成 ✅"
    info "服务状态: $(systemctl is-active $SERVICE_NAME)"
    info "监听端口: $PORT (UDP)"
    echo ""
    info "客户端链接："
    echo "${TUIC_URL}"
    echo ""
    info "⚠  tuic v5 使用自签名证书，客户端需关闭证书验证或导入证书"
    echo ""
    info "管理命令："
    info "启动: systemctl start $SERVICE_NAME"
    info "停止: systemctl stop $SERVICE_NAME"
    info "状态: systemctl status $SERVICE_NAME"
    info "日志: journalctl -u $SERVICE_NAME -f"
    info "======================"

    clean_temp
}

# ──────────────────────────────────────────────
# VLESS + Reality + TUIC v5 全安装
# ──────────────────────────────────────────────
function install_all() {
    download_singbox

    # VLESS 参数
    UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$($BIN_FILE generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    PORT_VLESS=$((RANDOM % 10000 + 10000))
    SNI_REALITY="gateway.icloud.com"
    SHORT_ID=$(openssl rand -hex 4)

    # TUIC 参数
    UUID_TUIC=$(cat /proc/sys/kernel/random/uuid)
    TUIC_PASS=$(openssl rand -base64 16 | tr -d '=+/')
    PORT_TUIC=$((RANDOM % 10000 + 20000))
    SNI_TUIC="salanghe.com"

    mkdir -p "$CONFIG_DIR"
    gen_self_signed_cert "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT_VLESS},
      "users": [
        {
          "uuid": "${UUID_VLESS}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI_REALITY}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI_REALITY}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${PORT_TUIC},
      "users": [
        {
          "uuid": "${UUID_TUIC}",
          "password": "${TUIC_PASS}"
        }
      ],
      "congestion_control": "bbr",
      "udp_relay_mode": "native",
      "zero_rtt_handshake": false,
      "tls": {
        "enabled": true,
        "server_name": "${SNI_TUIC}",
        "alpn": ["h3"],
        "certificate_path": "${CONFIG_DIR}/tuic.crt",
        "key_path": "${CONFIG_DIR}/tuic.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

    info "验证配置文件..."
    if ! $BIN_FILE check -c "$CONFIG_FILE"; then
        err "配置文件验证失败！"
        exit 1
    fi

    setup_systemd

    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    VLESS_URL="vless://${UUID_VLESS}@${SERVER_IP}:${PORT_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_REALITY}&fp=ios&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"
    TUIC_URL="tuic://${UUID_TUIC}:${TUIC_PASS}@${SERVER_IP}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI_TUIC}#TUIC"

    echo ""
    info "======================"
    info "Sing-Box 全协议安装完成 ✅"
    info "服务状态: $(systemctl is-active $SERVICE_NAME)"
    echo ""
    info "── VLESS + Reality ──"
    info "监听端口: $PORT_VLESS (TCP)"
    echo "${VLESS_URL}"
    echo ""
    info "── TUIC v5 ──"
    info "监听端口: $PORT_TUIC (UDP)"
    echo "${TUIC_URL}"
    echo ""
    info "⚠  tuic v5 使用自签名证书，客户端需关闭证书验证或导入证书"
    echo ""
    info "管理命令："
    info "启动: systemctl start $SERVICE_NAME"
    info "停止: systemctl stop $SERVICE_NAME"
    info "状态: systemctl status $SERVICE_NAME"
    info "日志: journalctl -u $SERVICE_NAME -f"
    info "======================"

    clean_temp
}

# ──────────────────────────────────────────────
# 添加 tuic 到已有安装（不改现有配置）
# ──────────────────────────────────────────────
function add_tuic() {
    if [ ! -f "$CONFIG_FILE" ]; then
        err "配置文件不存在，请先运行 install"
        exit 1
    fi

    UUID_TUIC=$(cat /proc/sys/kernel/random/uuid)
    TUIC_PASS=$(openssl rand -base64 16 | tr -d '=+/')
    PORT_TUIC=$((RANDOM % 10000 + 20000))
    SNI_TUIC="salanghe.com"

    gen_self_signed_cert "$CONFIG_DIR"

    # 读取现有配置，插入 tuic inbound
    # 方法：找到最后一个 inbound 的闭合 }}, 在其后添加 tuic
    # 更稳健：用 jq 操作
    if ! command -v jq &>/dev/null; then
        apt-get install -y jq
    fi

    # 检查是否已有 tuic inbound
    if jq -e '.inbounds[] | select(.type == "tuic")' "$CONFIG_FILE" >/dev/null 2>&1; then
        warn "已有 tuic inbound，跳过添加"
    else
        # 构建新 inbound
        TUIC_INBOUND=$(cat <<EOJ
{
  "type": "tuic",
  "tag": "tuic-in",
  "listen": "::",
  "listen_port": ${PORT_TUIC},
  "users": [
    {
      "uuid": "${UUID_TUIC}",
      "password": "${TUIC_PASS}"
    }
  ],
  "congestion_control": "bbr",
  "udp_relay_mode": "native",
  "zero_rtt_handshake": false,
  "tls": {
    "enabled": true,
    "server_name": "${SNI_TUIC}",
    "alpn": ["h3"],
    "certificate_path": "${CONFIG_DIR}/tuic.crt",
    "key_path": "${CONFIG_DIR}/tuic.key"
  }
}
EOJ
)

        jq --argjson tuic "$TUIC_INBOUND" '.inbounds += [$tuic]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

        info "验证配置文件..."
        if ! $BIN_FILE check -c "$CONFIG_FILE"; then
            err "配置文件验证失败！回滚..."
            mv "${CONFIG_FILE}.bak" "$CONFIG_FILE" 2>/dev/null || true
            exit 1
        fi

        systemctl restart "$SERVICE_NAME"
        sleep 2

        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            err "服务重启失败！"
            journalctl -u "$SERVICE_NAME" --no-pager -n 20
            exit 1
        fi

        SERVER_IP=$(curl -s ipv4.icanhazip.com)
        TUIC_URL="tuic://${UUID_TUIC}:${TUIC_PASS}@${SERVER_IP}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI_TUIC}#TUIC"

        echo ""
        info "TUIC v5 已添加到现有配置 ✅"
        info "监听端口: $PORT_TUIC (UDP)"
        echo "${TUIC_URL}"
        info "⚠  tuic v5 使用自签名证书，客户端需关闭证书验证或导入证书"
    fi
}

# ──────────────────────────────────────────────
# 卸载
# ──────────────────────────────────────────────
function uninstall_singbox() {
    info "正在停止 sing-box 服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    info "删除 systemd 服务文件..."
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    info "删除配置文件..."
    rm -rf "$CONFIG_DIR"

    info "删除二进制文件..."
    rm -f "$BIN_FILE"

    info "卸载完成 ✅"
}

# ──────────────────────────────────────────────
# 重启
# ──────────────────────────────────────────────
function restart_singbox() {
    info "重启 sing-box 服务..."
    systemctl restart "$SERVICE_NAME"
    sleep 2
    systemctl status "$SERVICE_NAME" --no-pager -l
}

# ──────────────────────────────────────────────
# 状态
# ──────────────────────────────────────────────
function status_singbox() {
    echo "=== 服务状态 ==="
    systemctl status "$SERVICE_NAME" --no-pager -l

    echo -e "\n=== 监听端口 ==="
    ss -tlnp | grep sing-box || echo "未找到 TCP 监听端口"
    ss -ulnp | grep sing-box || echo "未找到 UDP 监听端口"

    echo -e "\n=== 最近日志 ==="
    journalctl -u "$SERVICE_NAME" --no-pager -n 10
}

# ──────────────────────────────────────────────
# 查看配置
# ──────────────────────────────────────────────
function show_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        err "配置文件不存在: $CONFIG_FILE"
        return
    fi

    echo "=== 当前配置 ==="
    cat "$CONFIG_FILE"

    SERVER_IP=$(curl -s ipv4.icanhazip.com 2>/dev/null || echo "YOUR_SERVER_IP")

    echo -e "\n=== 连接信息 ==="

    # VLESS + Reality
    jq -c '.inbounds[] | select(.type == "vless")' "$CONFIG_FILE" 2>/dev/null | while read -r inbound; do
        UUID=$(echo "$inbound" | jq -r '.users[0].uuid // empty')
        PORT=$(echo "$inbound" | jq -r '.listen_port // empty')
        SHORT_ID=$(echo "$inbound" | jq -r '.tls.reality.short_id[0] // empty')
        PRIVATE_KEY=$(echo "$inbound" | jq -r '.tls.reality.private_key // empty')
        SNI=$(echo "$inbound" | jq -r '.tls.server_name // "gateway.icloud.com"')

        if [ -n "$PRIVATE_KEY" ] && [ -n "$BIN_FILE" ] && [ -f "$BIN_FILE" ]; then
            PUBLIC_KEY=$($BIN_FILE generate reality-keypair --private-key "$PRIVATE_KEY" 2>/dev/null | grep "PublicKey" | awk '{print $2}')
            if [ -n "$UUID" ] && [ -n "$PORT" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$SHORT_ID" ]; then
                VLESS_URL="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"
                echo "VLESS Reality: ${VLESS_URL}"
            fi
        fi
    done

    # TUIC v5
    jq -c '.inbounds[] | select(.type == "tuic")' "$CONFIG_FILE" 2>/dev/null | while read -r inbound; do
        UUID=$(echo "$inbound" | jq -r '.users[0].uuid // empty')
        PASS=$(echo "$inbound" | jq -r '.users[0].password // empty')
        PORT=$(echo "$inbound" | jq -r '.listen_port // empty')
        SNI=$(echo "$inbound" | jq -r '.tls.server_name // "salanghe.com"')

        if [ -n "$UUID" ] && [ -n "$PASS" ] && [ -n "$PORT" ]; then
            TUIC_URL="tuic://${UUID}:${PASS}@${SERVER_IP}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI}#TUIC"
            echo "TUIC v5:    ${TUIC_URL}"
        fi
    done
}

# ──────────────────────────────────────────────
# 菜单
# ──────────────────────────────────────────────
case "$1" in
    install)
        install_singbox
        ;;
    install-tuic)
        install_tuic
        ;;
    install-all)
        install_all
        ;;
    add-tuic)
        add_tuic
        ;;
    uninstall)
        uninstall_singbox
        ;;
    restart)
        restart_singbox
        ;;
    status)
        status_singbox
        ;;
    config)
        show_config
        ;;
    *)
        echo "用法: $0 {install|install-tuic|install-all|add-tuic|uninstall|restart|status|config}"
        echo ""
        echo "  install       - 安装 sing-box VLESS + Reality"
        echo "  install-tuic  - 安装 sing-box TUIC v5（自签证书）"
        echo "  install-all   - 安装 sing-box 双协议（vless+reality + tuic v5）"
        echo "  add-tuic      - 在已有安装上追加 tuic v5"
        echo "  uninstall     - 卸载 sing-box"
        echo "  restart       - 重启服务"
        echo "  status        - 查看服务状态"
        echo "  config        - 查看配置和连接信息"
        exit 1
        ;;
esac
