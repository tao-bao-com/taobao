#!/bin/bash

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo "请使用 root 用户运行此脚本" && exit 1

# --- 配置区 ---
TG_TOKEN="7756669471:AAFstxnzCweHItNptwOf7UU-p6xj3pwnAI8"
TG_CHAT_ID="1792396794"
SNI_DOMAIN="www.amazon.com"
# --------------

# 1. 安装基础依赖
apt update && apt install -y curl wget jq openssl docker.io docker-compose

# 2. 设置随机变量
SS_PORT=8388
LISTEN_PORT=443
SS_PASSWORD=$(openssl rand -base64 12 | tr -d /=+)
TLS_PASSWORD=$(openssl rand -base64 12 | tr -d /=+)
SERVER_IP=$(curl -s ipv4.icanhazip.com)

# 3. 创建工作目录
mkdir -p /opt/shadowtls-docker
cd /opt/shadowtls-docker

# 4. 创建 Shadowsocks 配置 (强制使用 Google DNS)
cat > ss-config.json <<EOF
{
    "server": "0.0.0.0",
    "server_port": $SS_PORT,
    "password": "$SS_PASSWORD",
    "method": "2022-blake3-aes-128-gcm",
    "timeout": 300,
    "nameserver": "8.8.8.8"
}
EOF

# 5. 创建 Docker Compose 配置文件
cat > docker-compose.yml <<EOF
version: '3.8'
services:
  ss-rust:
    image: ghcr.io/shadowsocks/ssserver-rust:latest
    container_name: ss-rust
    restart: always
    volumes:
      - ./ss-config.json:/etc/shadowsocks-rust/config.json
    command: ["ssserver", "-c", "/etc/shadowsocks-rust/config.json"]

  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    container_name: shadow-tls
    restart: always
    network_mode: "host"
    command: 
      - server
      - --listen
      - 0.0.0.0:$LISTEN_PORT
      - --server
      - 127.0.0.1:$SS_PORT
      - --tls
      - $SNI_DOMAIN:443
      - --password
      - $TLS_PASSWORD
      - --v3
    depends_on:
      - ss-rust
EOF

# 6. 启动 Docker 容器
docker-compose up -d

# 7. 生成链接
SS_BASE64=$(echo -n "2022-blake3-aes-128-gcm:$SS_PASSWORD" | base64 | tr -d '\n')
RAW_LINK="ss://$SS_BASE64@$SERVER_IP:$LISTEN_PORT?plugin=shadow-tls%3Bhost%3D$SNI_DOMAIN%3Bpassword%3D$TLS_PASSWORD%3Bversion%3D3"

# 8. 发送 Telegram 通知
MSG="🚀 ShadowTLS 节点部署成功！
----------------------
服务器: $SERVER_IP
端口: $LISTEN_PORT
SNI: $SNI_DOMAIN
DNS: Google (8.8.8.8)
----------------------
小火箭链接 (点击复制):
$RAW_LINK"

curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$MSG" > /dev/null

# 9. 屏幕输出
clear
echo "======================================"
echo "部署完成！信息已推送到你的 Telegram。"
echo "======================================"
echo "节点链接:"
echo -e "\033[32m$RAW_LINK\033[0m"
