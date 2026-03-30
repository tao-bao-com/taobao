#!/bin/bash
set -e
apt-get update && apt-get install -y unzip curl
# ========== 配置区（可自定义）==========
LISTEN_PORT=10444
SNI_DOMAIN="www.taobao.com"
TG_TOKEN="7756669471:AAFstxnzCweHItNptwOf7UU-p6xj3pwnAI8"
TG_CHAT_ID="1792396794"
# =======================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 1. 安装依赖 ─────────────────────────────────────────────────
log "安装依赖..."
apt-get update -qq
apt-get install -y -qq unzip curl

# ── 2. 停止旧服务 ────────────────────────────────────────────────
log "停止旧容器和服务..."
docker rm -f ss-rust shadow-tls 2>/dev/null || true
systemctl stop xray 2>/dev/null || true
fuser -k ${LISTEN_PORT}/tcp 2>/dev/null || true
sleep 1

# ── 3. 安装 Xray ────────────────────────────────────────────────
log "安装 Xray..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
log "Xray 安装完成"

# ── 4. 生成密钥和 UUID ──────────────────────────────────────────
log "生成 Reality 密钥对..."
KEYS=$(xray x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYS"  | grep "Password"   | awk '{print $3}')

# 兼容不同版本输出格式
if [ -z "$PRIVATE_KEY" ]; then
    PRIVATE_KEY=$(echo "$KEYS" | grep -i "private" | awk '{print $NF}')
fi
if [ -z "$PUBLIC_KEY" ]; then
    PUBLIC_KEY=$(echo "$KEYS" | grep -i "public" | awk '{print $NF}')
fi

[ -z "$PRIVATE_KEY" ] && err "私钥生成失败，请检查 xray x25519 输出"
[ -z "$PUBLIC_KEY"  ] && err "公钥生成失败，请检查 xray x25519 输出"

log "生成 UUID..."
UUID=$(xray uuid)
[ -z "$UUID" ] && err "UUID 生成失败"

SHORT_ID=$(openssl rand -hex 8)

log "密钥生成完成"
log "私钥: ${PRIVATE_KEY}"
log "公钥: ${PUBLIC_KEY}"
log "UUID: ${UUID}"
log "Short ID: ${SHORT_ID}"

# ── 5. 写入 Xray 配置 ───────────────────────────────────────────
log "写入配置文件..."
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": ${LISTEN_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SNI_DOMAIN}:443",
        "serverNames": ["${SNI_DOMAIN}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http","tls"]
    }
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF

# 验证私钥是否写入
WRITTEN_KEY=$(grep -o '"privateKey": "[^"]*"' /usr/local/etc/xray/config.json | awk -F'"' '{print $4}')
if [ -z "$WRITTEN_KEY" ] || [ "$WRITTEN_KEY" = "" ]; then
    err "私钥写入配置文件失败，请手动检查"
fi
log "配置文件写入成功"

# ── 6. 启动 Xray ────────────────────────────────────────────────
log "启动 Xray 服务..."
systemctl enable xray
systemctl restart xray
sleep 3

STATUS=$(systemctl is-active xray)
if [ "$STATUS" != "active" ]; then
    warn "Xray 启动失败，错误日志："
    journalctl -u xray -n 30 --no-pager
    err "请根据上方日志排查问题"
fi
log "Xray 运行正常 ✅"

# ── 7. 获取公网 IP ──────────────────────────────────────────────
log "获取公网 IP..."
SERVER_IP=$(curl -s --max-time 10 ipv4.icanhazip.com || \
            curl -s --max-time 10 api.ipify.org      || \
            curl -s --max-time 10 ifconfig.me)
[ -z "$SERVER_IP" ] && err "无法获取公网 IP"
log "服务器 IP：${SERVER_IP}"

# ── 8. 生成 Mihomo/Clash 配置 ───────────────────────────────────
CLASH_CONFIG="mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false

proxies:
  - name: \"Reality节点\"
    type: vless
    server: ${SERVER_IP}
    port: ${LISTEN_PORT}
    uuid: ${UUID}
    flow: xtls-rprx-vision
    tls: true
    servername: ${SNI_DOMAIN}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: random

proxy-groups:
  - name: \"Proxy\"
    type: select
    proxies:
      - \"Reality节点\"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - DOMAIN-SUFFIX,cn,DIRECT
  - MATCH,Proxy"

# ── 9. 推送到 Telegram ──────────────────────────────────────────
log "推送配置到 Telegram..."
curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=✅ VLESS+Reality 部署完成

🌐 服务器IP：${SERVER_IP}
🔑 UUID：${UUID}
🔐 公钥：${PUBLIC_KEY}
🆔 Short ID：${SHORT_ID}
🌍 SNI：${SNI_DOMAIN}
🔌 端口：${LISTEN_PORT}

📋 Mihomo/Clash 配置：
\`\`\`
${CLASH_CONFIG}
\`\`\`" >/dev/null

# ── 10. 本地输出汇总 ────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  🎉 部署完成！"
echo "════════════════════════════════════════════════════════"
echo "  服务器IP   : ${SERVER_IP}"
echo "  UUID       : ${UUID}"
echo "  公钥       : ${PUBLIC_KEY}"
echo "  Short ID   : ${SHORT_ID}"
echo "  SNI        : ${SNI_DOMAIN}"
echo "  端口       : ${LISTEN_PORT}"
echo "════════════════════════════════════════════════════════"
echo ""
echo "📋 Mihomo Party / Clash Verge Rev 配置文件内容："
echo "────────────────────────────────────────────────────────"
echo "${CLASH_CONFIG}"
echo "────────────────────────────────────────────────────────"
echo ""
echo "✅ 配置已推送到 Telegram，请查收！"
echo ""
log "导入上方配置到 Mihomo Party，开启系统代理即可使用"
