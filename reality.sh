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
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERR]${NC} $1"; }

# ──────────────────────────────────────────────
# 全局检测变量
# ──────────────────────────────────────────────
SB_INSTALLED=false
SB_RUNNING=false
HAS_VLESS=false
HAS_TUIC=false
HAS_HY2=false
PORT_VLESS=""
PORT_TUIC=""
PORT_HY2=""

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
# 生成自签名证书（用于 QUIC 协议：tuic / hysteria2）
# ──────────────────────────────────────────────
function gen_self_signed_cert() {
    local CERT_DIR="$1"
    mkdir -p "$CERT_DIR"
    if [ ! -f "$CERT_DIR/server.crt" ] || [ ! -f "$CERT_DIR/server.key" ]; then
        info "生成自签名证书..."
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 3650 -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
            -subj "/CN=salanghe.com" -addext "subjectAltName=DNS:salanghe.com"
        info "证书已生成: $CERT_DIR/server.crt"
    else
        info "证书已存在，跳过生成"
    fi
}

# ──────────────────────────────────────────────
# 智能检测当前安装状态
# ──────────────────────────────────────────────
function detect_installation() {
    SB_INSTALLED=false; SB_RUNNING=false
    HAS_VLESS=false; HAS_TUIC=false; HAS_HY2=false
    PORT_VLESS=""; PORT_TUIC=""; PORT_HY2=""

    [ -f "$BIN_FILE" ] && SB_INSTALLED=true
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && SB_RUNNING=true

    if [ -f "$CONFIG_FILE" ] && command -v jq &>/dev/null; then
        for t in $(jq -r '.inbounds[].type' "$CONFIG_FILE" 2>/dev/null || echo ""); do
            case "$t" in
                vless)     HAS_VLESS=true ;;
                tuic)      HAS_TUIC=true ;;
                hysteria2) HAS_HY2=true ;;
            esac
        done
        $HAS_VLESS && PORT_VLESS=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port' "$CONFIG_FILE" 2>/dev/null)
        $HAS_TUIC && PORT_TUIC=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' "$CONFIG_FILE" 2>/dev/null)
        $HAS_HY2  && PORT_HY2=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "$CONFIG_FILE" 2>/dev/null)
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

    cp "$SRC" "$BIN_FILE"
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
# VLESS + Reality 安装（全新 standalone）
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
# TUIC v5 安装（全新 standalone）
# ──────────────────────────────────────────────
function install_tuic() {
    download_singbox

    UUID=$(cat /proc/sys/kernel/random/uuid)
    TUIC_PASS=$(openssl rand -base64 16 | tr -d '=+/')
    PORT=$((RANDOM % 10000 + 20000))
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
      "zero_rtt_handshake": false,
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "alpn": ["h3"],
        "certificate_path": "${CONFIG_DIR}/server.crt",
        "key_path": "${CONFIG_DIR}/server.key"
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
    TUIC_URL="tuic://${UUID}:${TUIC_PASS}@${SERVER_IP}:${PORT}?congestion_control=bbr&alpn=h3&sni=${SNI}#TUIC"

    echo ""
    info "======================"
    info "Sing-Box TUIC v5 安装完成 ✅"
    echo ""
    info "客户端链接："
    echo "${TUIC_URL}"
    echo ""
    info "⚠  tuic v5 使用自签名证书，客户端需关闭证书验证"
    info "======================"

    clean_temp
}

# ──────────────────────────────────────────────
# Hysteria2 安装（全新 standalone）
# ──────────────────────────────────────────────
function install_hy2() {
    download_singbox

    HY2_PASS=$(openssl rand -base64 16 | tr -d '=+/')
    OBFS_PASS=$(openssl rand -base64 12 | tr -d '=+/')
    PORT=$((RANDOM % 10000 + 30000))
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
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "password": "${HY2_PASS}"
        }
      ],
      "obfs": {
        "type": "strange",
        "password": "${OBFS_PASS}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "alpn": ["h3"],
        "certificate_path": "${CONFIG_DIR}/server.crt",
        "key_path": "${CONFIG_DIR}/server.key"
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
    HY2_URL="hysteria2://${HY2_PASS}@${SERVER_IP}:${PORT}?insecure=1&obfs=salamander&obfs-password=${OBFS_PASS}&sni=${SNI}&alpn=h3#Hysteria2"

    echo ""
    info "======================"
    info "Sing-Box Hysteria2 安装完成 ✅"
    echo ""
    info "客户端链接："
    echo "${HY2_URL}"
    echo ""
    info "⚠  Hysteria2 使用自签名证书，客户端需关证书验证(?insecure=1)"
    info "======================"

    clean_temp
}

# ──────────────────────────────────────────────
# 三协议全安装
# ──────────────────────────────────────────────
function install_all() {
    download_singbox

    UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$($BIN_FILE generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    PORT_VLESS=$((RANDOM % 10000 + 10000))
    SNI_REALITY="gateway.icloud.com"
    SHORT_ID=$(openssl rand -hex 4)

    UUID_TUIC=$(cat /proc/sys/kernel/random/uuid)
    TUIC_PASS=$(openssl rand -base64 16 | tr -d '=+/')
    PORT_TUIC=$((RANDOM % 10000 + 20000))
    SNI_TUIC="salanghe.com"

    HY2_PASS=$(openssl rand -base64 16 | tr -d '=+/')
    OBFS_PASS=$(openssl rand -base64 12 | tr -d '=+/')
    PORT_HY2=$((RANDOM % 10000 + 30000))
    SNI_HY2="salanghe.com"

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
      "zero_rtt_handshake": false,
      "tls": {
        "enabled": true,
        "server_name": "${SNI_TUIC}",
        "alpn": ["h3"],
        "certificate_path": "${CONFIG_DIR}/server.crt",
        "key_path": "${CONFIG_DIR}/server.key"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT_HY2},
      "users": [
        {
          "password": "${HY2_PASS}"
        }
      ],
      "obfs": {
        "type": "strange",
        "password": "${OBFS_PASS}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${SNI_HY2}",
        "alpn": ["h3"],
        "certificate_path": "${CONFIG_DIR}/server.crt",
        "key_path": "${CONFIG_DIR}/server.key"
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
    TUIC_URL="tuic://${UUID_TUIC}:${TUIC_PASS}@${SERVER_IP}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&sni=${SNI_TUIC}#TUIC"
    HY2_URL="hysteria2://${HY2_PASS}@${SERVER_IP}:${PORT_HY2}?insecure=1&obfs=salamander&obfs-password=${OBFS_PASS}&sni=${SNI_HY2}&alpn=h3#Hysteria2"

    echo ""
    info "===================================="
    info "Sing-Box 三协议安装完成 ✅"
    echo ""
    info "── 1. VLESS + Reality ──────────────"
    echo "${VLESS_URL}"
    echo ""
    info "── 2. TUIC v5 ──────────────────────"
    echo "${TUIC_URL}"
    echo ""
    info "── 3. Hysteria2 ────────────────────"
    echo "${HY2_URL}"
    echo ""
    info "⚠  tuic / hysteria2 均使用自签名证书，客户端需关证书验证"
    info "===================================="

    clean_temp
}

# ══════════════════════════════════════════
# 以下为追加/增量函数（向已有配置添加协议）
# ══════════════════════════════════════════

# ──────────────────────────────────────────────
# 追加 VLESS + Reality 到已有配置
# ──────────────────────────────────────────────
function add_vless() {
    if ! $SB_INSTALLED; then
        install_singbox
        return
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        err "配置文件不存在"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then apt-get install -y jq; fi

    if jq -e '.inbounds[] | select(.type == "vless")' "$CONFIG_FILE" >/dev/null 2>&1; then
        warn "VLESS+Reality 已存在，跳过"
        return
    fi

    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$($BIN_FILE generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PORT=$((RANDOM % 10000 + 10000))
    SNI="gateway.icloud.com"
    SHORT_ID=$(openssl rand -hex 4)

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local inbound
    inbound=$(cat <<EOJ
{
  "type": "vless",
  "tag": "vless-in",
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
EOJ
)
    jq --argjson vless "$inbound" '.inbounds += [$vless]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    info "验证配置文件..."
    if ! $BIN_FILE check -c "$CONFIG_FILE"; then
        err "验证失败！回滚..."
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE" 2>/dev/null || true
        exit 1
    fi
    systemctl restart "$SERVICE_NAME"; sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "服务重启失败！"; journalctl -u "$SERVICE_NAME" --no-pager -n 20; exit 1
    fi

    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    PUBLIC_KEY=$($BIN_FILE generate reality-keypair --private-key "$PRIVATE_KEY" 2>/dev/null | grep "PublicKey" | awk '{print $2}')
    echo ""
    info "VLESS+Reality 已添加到现有配置 ✅"
    info "端口: $PORT"
    echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=ios&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"
    rm -f "${CONFIG_FILE}.bak"
}

# ──────────────────────────────────────────────
# 追加 TUIC v5 到已有配置
# ──────────────────────────────────────────────
function add_tuic() {
    if ! $SB_INSTALLED; then
        install_tuic
        return
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        err "配置文件不存在"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then apt-get install -y jq; fi
    if jq -e '.inbounds[] | select(.type == "tuic")' "$CONFIG_FILE" >/dev/null 2>&1; then
        warn "TUIC v5 已存在，跳过"
        return
    fi

    UUID=$(cat /proc/sys/kernel/random/uuid)
    TUIC_PASS=$(openssl rand -base64 16 | tr -d '=+/')
    PORT=$((RANDOM % 10000 + 20000))
    SNI="salanghe.com"

    gen_self_signed_cert "$CONFIG_DIR"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local inbound
    inbound=$(cat <<EOJ
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
  "zero_rtt_handshake": false,
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "alpn": ["h3"],
    "certificate_path": "${CONFIG_DIR}/server.crt",
    "key_path": "${CONFIG_DIR}/server.key"
  }
}
EOJ
)
    jq --argjson tuic "$inbound" '.inbounds += [$tuic]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    info "验证配置文件..."
    if ! $BIN_FILE check -c "$CONFIG_FILE"; then
        err "验证失败！回滚..."
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE" 2>/dev/null || true
        exit 1
    fi
    systemctl restart "$SERVICE_NAME"; sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "服务重启失败！"; journalctl -u "$SERVICE_NAME" --no-pager -n 20; exit 1
    fi

    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    echo ""
    info "TUIC v5 已添加到现有配置 ✅"
    info "端口: $PORT (UDP)"
    echo "tuic://${UUID}:${TUIC_PASS}@${SERVER_IP}:${PORT}?congestion_control=bbr&alpn=h3&sni=${SNI}#TUIC"
    info "⚠  tuic v5 使用自签名证书，客户端需关闭证书验证"
    rm -f "${CONFIG_FILE}.bak"
}

# ──────────────────────────────────────────────
# 追加 Hysteria2 到已有配置
# ──────────────────────────────────────────────
function add_hy2() {
    if ! $SB_INSTALLED; then
        install_hy2
        return
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        err "配置文件不存在"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then apt-get install -y jq; fi
    if jq -e '.inbounds[] | select(.type == "hysteria2")' "$CONFIG_FILE" >/dev/null 2>&1; then
        warn "Hysteria2 已存在，跳过"
        return
    fi

    HY2_PASS=$(openssl rand -base64 16 | tr -d '=+/')
    OBFS_PASS=$(openssl rand -base64 12 | tr -d '=+/')
    PORT=$((RANDOM % 10000 + 30000))
    SNI="salanghe.com"

    gen_self_signed_cert "$CONFIG_DIR"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local inbound
    inbound=$(cat <<EOJ
{
  "type": "hysteria2",
  "tag": "hy2-in",
  "listen": "::",
  "listen_port": ${PORT},
  "users": [
    {
      "password": "${HY2_PASS}"
    }
  ],
  "obfs": {
    "type": "strange",
    "password": "${OBFS_PASS}"
  },
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "alpn": ["h3"],
    "certificate_path": "${CONFIG_DIR}/server.crt",
    "key_path": "${CONFIG_DIR}/server.key"
  }
}
EOJ
)
    jq --argjson hy2 "$inbound" '.inbounds += [$hy2]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    info "验证配置文件..."
    if ! $BIN_FILE check -c "$CONFIG_FILE"; then
        err "验证失败！回滚..."
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE" 2>/dev/null || true
        exit 1
    fi
    systemctl restart "$SERVICE_NAME"; sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "服务重启失败！"; journalctl -u "$SERVICE_NAME" --no-pager -n 20; exit 1
    fi

    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    echo ""
    info "Hysteria2 已添加到现有配置 ✅"
    info "端口: $PORT (UDP)"
    echo "hysteria2://${HY2_PASS}@${SERVER_IP}:${PORT}?insecure=1&obfs=salamander&obfs-password=${OBFS_PASS}&sni=${SNI}&alpn=h3#Hysteria2"
    info "⚠  Hysteria2 使用自签名证书，客户端需关证书验证"
    rm -f "${CONFIG_FILE}.bak"
}

# ──────────────────────────────────────────────
# 安装所有缺失协议
# ──────────────────────────────────────────────
function install_missing() {
    detect_installation
    local changed=false

    if ! $SB_INSTALLED; then
        install_all
        return
    fi

    if ! $HAS_VLESS; then
        info "安装缺失的 VLESS+Reality ..."
        add_vless; changed=true
    fi
    if ! $HAS_TUIC; then
        info "安装缺失的 TUIC v5 ..."
        add_tuic; changed=true
    fi
    if ! $HAS_HY2; then
        info "安装缺失的 Hysteria2 ..."
        add_hy2; changed=true
    fi

    if ! $changed; then
        echo ""
        info "所有协议已安装，无需变更 ✅"
        show_config
    fi
}

# ──────────────────────────────────────────────
# 卸载
# ──────────────────────────────────────────────
function uninstall_singbox() {
    info "正在停止 sing-box 服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$CONFIG_DIR"
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
# 查看配置与链接
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

    jq -c '.inbounds[] | select(.type == "vless")' "$CONFIG_FILE" 2>/dev/null | while read -r inbound; do
        UUID=$(echo "$inbound" | jq -r '.users[0].uuid // empty')
        PORT=$(echo "$inbound" | jq -r '.listen_port // empty')
        SHORT_ID=$(echo "$inbound" | jq -r '.tls.reality.short_id[0] // empty')
        PRIVATE_KEY=$(echo "$inbound" | jq -r '.tls.reality.private_key // empty')
        SNI=$(echo "$inbound" | jq -r '.tls.server_name // "gateway.icloud.com"')
        if [ -n "$PRIVATE_KEY" ] && [ -f "$BIN_FILE" ]; then
            PUBLIC_KEY=$($BIN_FILE generate reality-keypair --private-key "$PRIVATE_KEY" 2>/dev/null | grep "PublicKey" | awk '{print $2}')
            if [ -n "$UUID" ] && [ -n "$PORT" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$SHORT_ID" ]; then
                echo "VLESS Reality: vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"
            fi
        fi
    done

    jq -c '.inbounds[] | select(.type == "tuic")' "$CONFIG_FILE" 2>/dev/null | while read -r inbound; do
        UUID=$(echo "$inbound" | jq -r '.users[0].uuid // empty')
        PASS=$(echo "$inbound" | jq -r '.users[0].password // empty')
        PORT=$(echo "$inbound" | jq -r '.listen_port // empty')
        SNI=$(echo "$inbound" | jq -r '.tls.server_name // "salanghe.com"')
        if [ -n "$UUID" ] && [ -n "$PASS" ] && [ -n "$PORT" ]; then
            echo "TUIC v5:    tuic://${UUID}:${PASS}@${SERVER_IP}:${PORT}?congestion_control=bbr&alpn=h3&sni=${SNI}#TUIC"
        fi
    done

    jq -c '.inbounds[] | select(.type == "hysteria2")' "$CONFIG_FILE" 2>/dev/null | while read -r inbound; do
        PASS=$(echo "$inbound" | jq -r '.users[0].password // empty')
        PORT=$(echo "$inbound" | jq -r '.listen_port // empty')
        OBFS_PASS=$(echo "$inbound" | jq -r '.obfs.password // empty')
        SNI=$(echo "$inbound" | jq -r '.tls.server_name // "salanghe.com"')
        if [ -n "$PASS" ] && [ -n "$PORT" ]; then
            echo "Hysteria2:  hysteria2://${PASS}@${SERVER_IP}:${PORT}?insecure=1&obfs=salamander&obfs-password=${OBFS_PASS}&sni=${SNI}&alpn=h3#Hysteria2"
        fi
    done
}

# ══════════════════════════════════════════
# 交互管理菜单（智能检测）
# ══════════════════════════════════════════

function show_menu() {
    detect_installation

    local svc
    if ! $SB_INSTALLED; then svc="❌ 未安装"
    elif $SB_RUNNING; then svc="✅ 运行中"
    else svc="⚠️ 已停止"; fi

    # 协议状态
    local s_vless="❌" s_tuic="❌" s_hy2="❌"
    $HAS_VLESS && s_vless="✅"
    $HAS_TUIC && s_tuic="✅"
    $HAS_HY2 && s_hy2="✅"

    clear 2>/dev/null || true
    echo "╔═══════════════════════════════════════════╗"
    echo "║         Sing-Box 管理面板                 ║"
    echo "╠═══════════════════════════════════════════╣"
    echo "║  服务: $svc"
    echo "║"
    printf "║  %-3s %-20s %s   %s\n" "1." "VLESS + Reality" "$s_vless" "${PORT_VLESS:+端口 $PORT_VLESS}"
    printf "║  %-3s %-20s %s   %s\n" "2." "TUIC v5" "$s_tuic" "${PORT_TUIC:+端口 $PORT_TUIC}"
    printf "║  %-3s %-20s %s   %s\n" "3." "Hysteria2" "$s_hy2" "${PORT_HY2:+端口 $PORT_HY2}"
    echo "║"
    echo "║  4. 安装全部缺失协议"
    echo "║  5. 查看配置与链接"
    echo "║  6. 重启服务"
    if $SB_INSTALLED; then
        echo "║  7. 卸载 sing-box"
    fi
    echo "║  0. 退出"
    echo "╚═══════════════════════════════════════════╝"
    echo ""
    echo -n "请选择 [0-7]: "
    read -r choice

    case "$choice" in
        0) exit 0 ;;
        1)
            if $HAS_VLESS; then
                echo ""
                show_config 2>/dev/null | grep -A2 "VLESS" || show_config
            else
                add_vless
            fi
            ;;
        2)
            if $HAS_TUIC; then
                echo ""
                show_config 2>/dev/null | grep -A2 "TUIC" || show_config
            else
                add_tuic
            fi
            ;;
        3)
            if $HAS_HY2; then
                echo ""
                show_config 2>/dev/null | grep -A2 "Hysteria2" || show_config
            else
                add_hy2
            fi
            ;;
        4) install_missing ;;
        5) show_config ;;
        6) restart_singbox ;;
        7) $SB_INSTALLED && uninstall_singbox ;;
        *) warn "无效选项" ;;
    esac

    echo ""
    echo -n "按回车返回主菜单..."
    read -r
    show_menu
}

# ══════════════════════════════════════════
# 命令行入口
# ══════════════════════════════════════════

case "${1:-menu}" in
    menu|manage)
        show_menu
        ;;
    install)
        install_singbox
        ;;
    install-tuic)
        install_tuic
        ;;
    install-hy2)
        install_hy2
        ;;
    install-all)
        install_all
        ;;
    install-missing)
        install_missing
        ;;
    add-vless)
        add_vless
        ;;
    add-tuic)
        add_tuic
        ;;
    add-hy2)
        add_hy2
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
        echo "用法: $0 [命令]"
        echo ""
        echo "  无参数 / menu   - 交互管理菜单（智能检测）"
        echo "  install         - 安装 VLESS + Reality"
        echo "  install-tuic    - 安装 TUIC v5"
        echo "  install-hy2     - 安装 Hysteria2"
        echo "  install-all     - 三协议同时安装"
        echo "  install-missing - 只装缺失的协议"
        echo "  add-vless       - 追加 VLESS 到已有安装"
        echo "  add-tuic        - 追加 TUIC 到已有安装"
        echo "  add-hy2         - 追加 Hysteria2 到已有安装"
        echo "  uninstall       - 卸载"
        echo "  restart         - 重启服务"
        echo "  status          - 状态与端口"
        echo "  config          - 查看配置与链接"
        exit 1
        ;;
esac
