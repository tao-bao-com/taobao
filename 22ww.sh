#!/bin/bash
set -e

# ========== 配置区 ==========
TG_TOKEN="7756669471:AAFstxnzCweHItNptwOf7UU-p6xj3pwnAI8"
TG_CHAT_ID="1792396794"
SNI_DOMAIN="aws.amazon.com"
TLS_PWD="CDSA504C9S8AD7FV41F9DA84VFD149"
SS_PORT=3566
LISTEN_PORT=3522
# ============================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 1. 安装 Docker ──────────────────────────────────────────────
log "检查 Docker 环境..."
if ! command -v docker &>/dev/null; then
    warn "Docker 未安装，正在安装..."
    apt-get update -qq && apt-get install -y -qq docker.io
    systemctl start docker && systemctl enable docker
    log "Docker 安装完成"
fi
docker info &>/dev/null || err "Docker 守护进程未运行，请检查"

# ── 2. 深度清理旧容器和占用端口 ────────────────────────────────
log "清理旧容器..."
docker rm -f ss-rust shadow-tls 2>/dev/null || true
sleep 1
fuser -k ${LISTEN_PORT}/tcp 2>/dev/null || true
fuser -k ${SS_PORT}/tcp     2>/dev/null || true
sleep 1

# ── 3. 固定 SS 2022 密钥 ────────────────────────────────────────
log "使用固定 SS 2022 密钥..."
SS_KEY="1/1w3cCjCCCwhXGlyRe2/A=="
log "SS 密钥：$SS_KEY"

# ── 4. 启动内层 Shadowsocks-Rust 容器 ──────────────────────────
log "启动 Shadowsocks-Rust 容器..."
docker run -d \
    --name ss-rust \
    --restart always \
    --network host \
    ghcr.io/shadowsocks/ssserver-rust:latest \
    ssserver \
        --server-addr "127.0.0.1:${SS_PORT}" \
        --encrypt-method "2022-blake3-aes-128-gcm" \
        --password "${SS_KEY}" \
        --timeout 300 \
        -U

log "等待 Shadowsocks 启动..."
for i in $(seq 1 15); do
    if docker exec ss-rust ss -tlnp 2>/dev/null | grep -q "${SS_PORT}" || \
       ss -tlnp 2>/dev/null | grep -q "${SS_PORT}"; then
        log "Shadowsocks 已在 127.0.0.1:${SS_PORT} 监听"
        break
    fi
    if [ $i -eq 15 ]; then
        warn "等待超时，继续尝试（查看日志：docker logs ss-rust）"
        docker logs ss-rust 2>&1 | tail -20
    fi
    sleep 1
done

# ── 5. 启动外层 Shadow-TLS 容器 ────────────────────────────────
log "启动 Shadow-TLS 容器..."
docker run -d \
    --name shadow-tls \
    --restart always \
    --network host \
    --entrypoint shadow-tls \
    ghcr.io/ihciah/shadow-tls:v0.2.23 \
    --v3 server \
    --listen "0.0.0.0:${LISTEN_PORT}" \
    --server "127.0.0.1:${SS_PORT}" \
    --tls "${SNI_DOMAIN}:443" \
    --password "${TLS_PWD}"

sleep 3

# ── 6. 验证容器状态 ─────────────────────────────────────────────
log "验证容器运行状态..."
SS_STATUS=$(docker inspect -f '{{.State.Status}}' ss-rust 2>/dev/null)
TLS_STATUS=$(docker inspect -f '{{.State.Status}}' shadow-tls 2>/dev/null)

if [ "$SS_STATUS" != "running" ]; then
    warn "ss-rust 状态异常: $SS_STATUS"
    docker logs ss-rust 2>&1 | tail -30
fi
if [ "$TLS_STATUS" != "running" ]; then
    warn "shadow-tls 状态异常: $TLS_STATUS"
    docker logs shadow-tls 2>&1 | tail -30
fi

# ── 7. 获取服务器公网 IP ────────────────────────────────────────
log "获取公网 IP..."
SERVER_IP=$(curl -s --max-time 10 ipv4.icanhazip.com || \
            curl -s --max-time 10 api.ipify.org || \
            curl -s --max-time 10 ifconfig.me)
[ -z "$SERVER_IP" ] && err "无法获取公网 IP"
log "服务器 IP：$SERVER_IP"

# ── 8. 生成 Shadowrocket 专用节点链接 ──────────────────────────
# 格式：ss://BASE64(method:password)@host:port?shadow-tls=BASE64(JSON)#name
log "生成节点链接..."

SS_B64=$(python3 -c "
import base64
raw = '2022-blake3-aes-128-gcm:${SS_KEY}'
b64 = base64.urlsafe_b64encode(raw.encode()).decode().rstrip('=')
print(b64)
")

STLS_B64=$(python3 -c "
import base64, json
obj = {'version': '3', 'host': '${SNI_DOMAIN}', 'password': '${TLS_PWD}'}
b64 = base64.urlsafe_b64encode(json.dumps(obj, separators=(',',':')).encode()).decode().rstrip('=')
print(b64)
")

SS_LINK="ss://${SS_B64}@${SERVER_IP}:${LISTEN_PORT}?shadow-tls=${STLS_B64}#SS2022_ShadowTLS"

# ── 9. 推送节点链接到 Telegram ─────────────────────────────────
log "推送配置到 Telegram..."
curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=🔗 小火箭一键链接:
${SS_LINK}" >/dev/null

# ── 10. 本地输出汇总 ────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════"
echo "  部署完成汇总"
echo "══════════════════════════════════════════════"
echo "  服务器IP    : ${SERVER_IP}"
echo "  监听端口    : ${LISTEN_PORT}"
echo "  SS端口      : ${SS_PORT} (仅本机)"
echo "  加密算法    : 2022-blake3-aes-128-gcm"
echo "  SS 密码     : ${SS_KEY}"
echo "  TLS 密码    : ${TLS_PWD}"
echo "  SNI 域名    : ${SNI_DOMAIN}"
echo "══════════════════════════════════════════════"
echo "  一键链接:"
echo "  ${SS_LINK}"
echo "══════════════════════════════════════════════"
echo ""
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
log "配置已推送到 Telegram，请查收！"
