#!/usr/bin/env bash
# bootstrap-exit.sh — разворачивает bridge-xray на foreign-ноде
# и печатает готовые JSON-блоки для копи-пасты в Remnawave Config Profile.
#
# Использование (на foreign-сервере, root):
#   BRIDGE_UUID=... \
#   BRIDGE_REALITY_PRIV=... \
#   BRIDGE_REALITY_SHORTID=... \
#   ENTRY_IP=45.152.198.131 \
#   ENTRY_PORT=2087 \
#   bash <(curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/bootstrap-exit.sh) <country_code>
#
# Пример:
#   BRIDGE_UUID=... BRIDGE_REALITY_PRIV=... BRIDGE_REALITY_SHORTID=... \
#   ENTRY_IP=45.152.198.131 ENTRY_PORT=2087 \
#   bash <(curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/bootstrap-exit.sh) us

set -euo pipefail

# ─────────────── Параметры и валидация ───────────────
COUNTRY="${1:-}"
[ -z "$COUNTRY" ] && { echo "❌ Usage: $0 <country_code> (например: us / fr / de / kz)"; exit 1; }
COUNTRY_UPPER=$(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]')

: "${BRIDGE_UUID:?❌ ENV BRIDGE_UUID обязателен (общий для всех мостов)}"
: "${BRIDGE_REALITY_PRIV:?❌ ENV BRIDGE_REALITY_PRIV обязателен (Reality private key для bridge-inbound)}"
: "${BRIDGE_REALITY_SHORTID:?❌ ENV BRIDGE_REALITY_SHORTID обязателен (общий shortId для моста)}"
: "${ENTRY_IP:?❌ ENV ENTRY_IP обязателен (IP вашей entry-ноды, например 45.152.198.131)}"
: "${ENTRY_PORT:?❌ ENV ENTRY_PORT обязателен (свободный порт на entry-ноде для VLESS_${COUNTRY_UPPER} inbound)}"

BRIDGE_REALITY_SNI="${BRIDGE_REALITY_SNI:-max.ru}"
BRIDGE_REALITY_DEST="${BRIDGE_REALITY_DEST:-max.ru:443}"
BRIDGE_PORT="${BRIDGE_PORT:-7443}"
XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:latest}"
INSTALL_DIR="${INSTALL_DIR:-/opt/bridge-xray}"

# Подбор SNI для клиентского inbound по стране (можно переопределить через CLIENT_SNI)
client_sni_for_country() {
  case "$1" in
    us|usa)   echo "amazon.com" ;;
    uk|gb)    echo "bbc.co.uk" ;;
    fr)       echo "wildberries.ru" ;;
    de)       echo "vk.com" ;;
    nl)       echo "ozon.ru" ;;
    pl)       echo "yandex.ru" ;;
    kz)       echo "mail.ru" ;;
    ru)       echo "rambler.ru" ;;
    jp)       echo "rakuten.co.jp" ;;
    sg)       echo "shopee.sg" ;;
    fi)       echo "yle.fi" ;;
    se)       echo "svt.se" ;;
    *)        echo "cloudflare.com" ;;
  esac
}
CLIENT_SNI="${CLIENT_SNI:-$(client_sni_for_country "$COUNTRY")}"

step() { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m  ✓ %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m  ⚠ %s\033[0m\n" "$*"; }

# ─────────────── 0. Privilege check ───────────────
[ "$EUID" -ne 0 ] && { echo "❌ Запусти от root (sudo bash ...)"; exit 1; }

# ─────────────── 1. Установка Docker ───────────────
step "Проверяю Docker"
if ! command -v docker >/dev/null 2>&1; then
  step "Устанавливаю Docker"
  if   command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -yqq curl ca-certificates
    curl -fsSL https://get.docker.com | sh
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q dnf-plugins-core curl
    curl -fsSL https://get.docker.com | sh
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl
    curl -fsSL https://get.docker.com | sh
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache docker curl openrc
    rc-update add docker boot
    service docker start
  else
    echo "❌ Не нашёл apt/dnf/yum/apk — поставь Docker вручную и перезапусти"; exit 1
  fi
  systemctl enable --now docker 2>/dev/null || true
  ok "Docker установлен ($(docker --version))"
else
  ok "Docker уже стоит: $(docker --version)"
fi

# ─────────────── 2. Открыть порт 7443 ───────────────
step "Открываю порт ${BRIDGE_PORT}/tcp"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow ${BRIDGE_PORT}/tcp >/dev/null && ok "UFW: ${BRIDGE_PORT}/tcp разрешён"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
  firewall-cmd --permanent --add-port=${BRIDGE_PORT}/tcp >/dev/null && firewall-cmd --reload >/dev/null
  ok "firewalld: ${BRIDGE_PORT}/tcp разрешён"
elif command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport ${BRIDGE_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${BRIDGE_PORT} -j ACCEPT
  ok "iptables: правило для ${BRIDGE_PORT}/tcp добавлено (в runtime, для persistence настрой сам)"
else
  warn "Не нашёл UFW/firewalld/iptables — убедись что ${BRIDGE_PORT}/tcp доступен извне"
fi

# ─────────────── 3. Развёртывание bridge-xray ───────────────
step "Создаю конфиг ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"

cat > "${INSTALL_DIR}/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "tag": "BRIDGE_INBOUND",
    "port": ${BRIDGE_PORT},
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "${BRIDGE_UUID}",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${BRIDGE_REALITY_DEST}",
        "xver": 0,
        "serverNames": ["${BRIDGE_REALITY_SNI}"],
        "privateKey": "${BRIDGE_REALITY_PRIV}",
        "shortIds": ["${BRIDGE_REALITY_SHORTID}"]
      }
    }
  }],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom", "settings": { "domainStrategy": "UseIP" } }
  ]
}
EOF

cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  bridge-xray:
    image: ${XRAY_IMAGE}
    container_name: bridge-xray
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    command: ["run", "-c", "/etc/xray/config.json"]
EOF
ok "config.json + docker-compose.yml созданы"

step "Запускаю bridge-xray"
cd "${INSTALL_DIR}"
docker rm -f bridge-xray 2>/dev/null || true
if docker compose version >/dev/null 2>&1; then
  docker compose up -d
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose up -d
else
  docker run -d --name bridge-xray --restart unless-stopped --network host \
    -v "${INSTALL_DIR}/config.json:/etc/xray/config.json:ro" \
    "${XRAY_IMAGE}" run -c /etc/xray/config.json
fi
sleep 2
docker ps --filter name=bridge-xray --format "  ✓ {{.Names}}: {{.Status}}"

# ─────────────── 4. Smoke-test ───────────────
step "Smoke-test (TLS handshake на ${BRIDGE_PORT})"
if timeout 5 bash -c "</dev/tcp/127.0.0.1/${BRIDGE_PORT}" 2>/dev/null; then
  ok "Порт ${BRIDGE_PORT} слушается локально"
else
  warn "Порт ${BRIDGE_PORT} НЕ слушается — проверь docker logs bridge-xray"
fi

EXIT_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
ok "External IP этой ноды: ${EXIT_IP}"

# ─────────────── 5. Генерация client-side Reality keypair ───────────────
step "Генерирую client-side Reality keypair для VLESS_${COUNTRY_UPPER}"
KEYPAIR=$(docker run --rm "${XRAY_IMAGE}" x25519 2>/dev/null)
CLIENT_PRIV=$(echo "$KEYPAIR" | awk -F': ' '/Private/ {print $2}')
CLIENT_PUB=$(echo  "$KEYPAIR" | awk -F': ' '/Public/  {print $2}')
CLIENT_SHORTID=$(openssl rand -hex 8 2>/dev/null || head -c 16 /dev/urandom | xxd -p)
ok "Сгенерировано (уникально для ${COUNTRY_UPPER}):"
echo "    PrivateKey:  ${CLIENT_PRIV}"
echo "    PublicKey:   ${CLIENT_PUB}"
echo "    ShortId(16): ${CLIENT_SHORTID}"

# ─────────────── 6. Печать готовых блоков ───────────────
cat <<EOF

╔══════════════════════════════════════════════════════════════════╗
║  ✅ Bridge-xray развёрнут на ${EXIT_IP}:${BRIDGE_PORT}
║  Страна: ${COUNTRY_UPPER}
╚══════════════════════════════════════════════════════════════════╝

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1️⃣  ОТКРОЙ Remnawave Panel → Config Profiles → текущий → Edit Raw JSON
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ╔═══ Добавь в "inbounds" массив ═══╗
EOF

cat <<EOF
{
  "tag": "VLESS_${COUNTRY_UPPER}",
  "port": ${ENTRY_PORT},
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none",
    "flow": ""
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "dest": "${CLIENT_SNI}:443",
      "show": false,
      "xver": 0,
      "shortIds": ["${CLIENT_SHORTID}"],
      "privateKey": "${CLIENT_PRIV}",
      "serverNames": ["${CLIENT_SNI}"]
    }
  }
}
EOF

cat <<EOF

  ╔═══ Добавь в "outbounds" массив ═══╗
{
  "tag": "BRIDGE_${COUNTRY_UPPER}",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "${EXIT_IP}",
      "port": ${BRIDGE_PORT},
      "users": [{
        "id": "${BRIDGE_UUID}",
        "flow": "xtls-rprx-vision",
        "encryption": "none"
      }]
    }]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "shortId": "${BRIDGE_REALITY_SHORTID}",
      "spiderX": "",
      "publicKey": "<ВСТАВЬ публичный ключ от BRIDGE_REALITY_PRIV>",
      "serverName": "${BRIDGE_REALITY_SNI}",
      "fingerprint": "chrome"
    }
  }
}

  ╔═══ Добавь в "routing.rules" массив ═══╗
{
  "type": "field",
  "inboundTag": ["VLESS_${COUNTRY_UPPER}"],
  "outboundTag": "BRIDGE_${COUNTRY_UPPER}"
}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  2️⃣  СОЗДАЙ Host в Remnawave Panel → Hosts → New Host
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    Remark:       ${COUNTRY_UPPER} Test
    Inbound:      VLESS_${COUNTRY_UPPER}
    Address:      ${ENTRY_IP}
    Port:         ${ENTRY_PORT}
    SNI:          ${CLIENT_SNI}
    PublicKey:    ${CLIENT_PUB}
    ShortId:      ${CLIENT_SHORTID}
    Fingerprint:  chrome
    Security:     reality
    Network:      tcp
    Flow:         (пусто)
    Mux:          OFF (обязательно)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  3️⃣  Save → подписка автоматически обновится → клиенты подхватят
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF
