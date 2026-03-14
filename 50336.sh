#!/bin/bash
set -e

# ==========================================
# 1. 自定义配置区
# ==========================================
TG_TOKEN="7756669471:AAFstxnzCweHItNptwOf7UU-p6xj3pwnAI8"
TG_CHAT_ID="1792396794"

TROJAN_PORT=50336
TROJAN_PASSWORD="vds651vvafddvd977vdvd"
SNI_DOMAIN="manga.bilibili.com"
DOH_URL="https://1.1.1.2/dns-query"

# 锁定稳定版本，避免 latest 镜像更新导致配置格式变化
# 如果此版本不可用，可改为 v1.9.x 或 v1.8.x
SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:v1.10.7"

# ==========================================
# 2. 基础环境安装
# ==========================================
echo ">>> 正在安装基础环境..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl jq openssl

# 安装 Docker（Debian 12 官方推荐方式）
if ! command -v docker &>/dev/null; then
    echo ">>> 安装 Docker..."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

sudo systemctl enable --now docker

# 开启内核转发
sudo sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

# ==========================================
# 3. 准备工作目录与证书
# ==========================================
WORK_DIR=~/trojan_isolated
mkdir -p "$WORK_DIR/cert"
cd "$WORK_DIR"

# 证书只在不存在时才生成，避免重复部署时客户端指纹失效
if [ ! -f ./cert/server.crt ] || [ ! -f ./cert/server.key ]; then
    echo ">>> 生成自签名证书..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout ./cert/server.key -out ./cert/server.crt \
        -subj "/CN=$SNI_DOMAIN"
else
    echo ">>> 证书已存在，跳过生成（避免客户端指纹失效）"
fi

# ==========================================
# 4. 生成 sing-box 配置
# ==========================================
echo ">>> 生成 sing-box 配置..."
cat > config.json <<EOT
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "${DOH_URL}",
        "detour": "direct"
      }
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": ${TROJAN_PORT},
      "users": [
        {
          "name": "user1",
          "password": "${TROJAN_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI_DOMAIN}",
        "certificate_path": "/etc/sing-box/cert/server.crt",
        "key_path": "/etc/sing-box/cert/server.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOT

# ==========================================
# 5. 写入 docker-compose.yml（v2 格式，移除废弃的 version 字段）
# ==========================================
cat > docker-compose.yml <<EOT
services:
  sing-box:
    image: ${SINGBOX_IMAGE}
    container_name: trojan-isolated
    restart: always
    network_mode: host
    volumes:
      - ./config.json:/etc/sing-box/config.json
      - ./cert:/etc/sing-box/cert
    command: -D /var/lib/sing-box -c /etc/sing-box/config.json run
EOT

# ==========================================
# 6. 启动服务
# ==========================================
echo ">>> 启动 sing-box 容器..."
sudo docker compose down 2>/dev/null || true
sudo docker compose pull
sudo docker compose up -d

# 等待容器启动
sleep 3
echo ">>> 容器状态："
sudo docker compose ps

# ==========================================
# 7. 检查端口监听
# ==========================================
echo ">>> 检查端口 ${TROJAN_PORT} 监听状态..."
if sudo ss -tlnp | grep -q ":${TROJAN_PORT}"; then
    echo "✅ 端口 ${TROJAN_PORT} 已正常监听"
else
    echo "⚠️  端口 ${TROJAN_PORT} 未检测到监听，查看容器日志："
    sudo docker compose logs --tail=30
fi

# ==========================================
# 8. 强制获取 IPv4 地址
# ==========================================
# 使用多个备用源，确保拿到 IPv4
IP=""
for API in "https://api4.ipify.org" "https://ipv4.icanhazip.com" "https://v4.ident.me"; do
    IP=$(curl -4 -s --max-time 5 "$API" 2>/dev/null)
    if [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    IP=""
done

if [ -z "$IP" ]; then
    echo "⚠️  无法自动获取公网 IP，尝试从 EC2 元数据获取..."
    IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
fi

if [ -z "$IP" ]; then
    echo "❌ 无法获取公网 IP，请手动填写"
    IP="YOUR_SERVER_IP"
fi

# ==========================================
# 9. 输出链接与推送 Telegram
# ==========================================
RAW_LINK="trojan://${TROJAN_PASSWORD}@${IP}:${TROJAN_PORT}?sni=${SNI_DOMAIN}&allowInsecure=1#SingBox_Trojan_${IP}"

echo ""
echo "======================================================="
echo "✅ 部署完成！"
echo "服务器 IP  : $IP"
echo "端口       : $TROJAN_PORT"
echo "连接链接   : $RAW_LINK"
echo "======================================================="
echo ""
echo "⚠️  AWS EC2 提醒：请确认安全组已放行 TCP+UDP ${TROJAN_PORT} 端口！"
echo "   路径：EC2 控制台 -> 实例 -> 安全组 -> 入站规则"
echo ""

echo ">>> 推送链接至 Telegram..."
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${RAW_LINK}")

if echo "$RESPONSE" | grep -q '"ok":true'; then
    echo "✅ Telegram 推送成功！"
else
    echo "❌ Telegram 推送失败，详情: $RESPONSE"
fi
