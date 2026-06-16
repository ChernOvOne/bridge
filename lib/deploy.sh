#!/usr/bin/env bash
# lib/deploy.sh — установка Docker, развёртывание bridge-xray (Reality/xhttp/WG), iperf3, удаление.

XRAY_IMAGE_DEFAULT="ghcr.io/xtls/xray-core:latest"
IPERF3_IMAGE="networkstatic/iperf3:latest"
BRIDGE_DIR_DEFAULT="/opt/bridge-xray"

detect_pkg_mgr() {
  if   command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf     >/dev/null 2>&1; then echo dnf
  elif command -v yum     >/dev/null 2>&1; then echo yum
  elif command -v apk     >/dev/null 2>&1; then echo apk
  else echo unknown
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker уже установлен ($(docker --version))"
    return 0
  fi
  step "Устанавливаю Docker через get.docker.com"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true
  ok "Docker установлен"
}

# Открыть порт TCP в активном файрволе (UFW/firewalld/iptables)
open_port_tcp() {
  local port="$1"; local src_ip="${2:-}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [ -n "$src_ip" ]; then
      ufw allow from "$src_ip" to any port "$port" proto tcp >/dev/null 2>&1
    else
      ufw allow "${port}/tcp" >/dev/null 2>&1
    fi
    ok "UFW: открыт ${port}/tcp${src_ip:+ от $src_ip}"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld: открыт ${port}/tcp"
  elif command -v iptables >/dev/null 2>&1; then
    if [ -n "$src_ip" ]; then
      iptables -C INPUT -p tcp -s "$src_ip" --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp -s "$src_ip" --dport "$port" -j ACCEPT
    else
      iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    fi
    ok "iptables: открыт ${port}/tcp${src_ip:+ от $src_ip}"
  else
    warn "Не нашёл UFW/firewalld/iptables — убедитесь что ${port}/tcp доступен"
  fi
}

# Развёртывание Reality+TCP+Vision bridge-xray контейнера
deploy_bridge_reality() {
  local bridge_name="$1"
  local port="$2"
  local uuid="$3"
  local reality_priv="$4"
  local reality_shortid="$5"
  local reality_sni="$6"
  local reality_dest="$7"
  local install_dir="${BRIDGE_DIR_DEFAULT}/${bridge_name}"
  local container_name="bridge-xray-${bridge_name}"

  mkdir -p "$install_dir"

  cat > "${install_dir}/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "tag": "BRIDGE_INBOUND",
    "port": ${port},
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${reality_dest}",
        "xver": 0,
        "serverNames": ["${reality_sni}"],
        "privateKey": "${reality_priv}",
        "shortIds": ["${reality_shortid}"]
      }
    }
  }],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom", "settings": { "domainStrategy": "UseIP" } }
  ]
}
EOF

  docker rm -f "$container_name" 2>/dev/null || true
  docker run -d --name "$container_name" --restart unless-stopped --network host \
    -v "${install_dir}/config.json:/etc/xray/config.json:ro" \
    "${XRAY_IMAGE:-$XRAY_IMAGE_DEFAULT}" run -c /etc/xray/config.json >/dev/null
  sleep 2
  if docker ps --filter "name=$container_name" --format '{{.Names}}' | grep -q "$container_name"; then
    ok "Контейнер $container_name запущен на :$port (Reality+TCP+Vision)"
  else
    err "Контейнер $container_name не запустился — см. docker logs"
    return 1
  fi
  open_port_tcp "$port"
}

# Развёртывание Reality+xhttp bridge — рекомендуется для UDP-DNS-чувствительных клиентов
deploy_bridge_xhttp() {
  local bridge_name="$1" port="$2" uuid="$3" reality_priv="$4"
  local reality_shortid="$5" reality_sni="$6" reality_dest="$7"
  local install_dir="${BRIDGE_DIR_DEFAULT}/${bridge_name}"
  local container_name="bridge-xray-${bridge_name}"

  mkdir -p "$install_dir"

  cat > "${install_dir}/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "tag": "BRIDGE_INBOUND",
    "port": ${port},
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${uuid}"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "xhttpSettings": {
        "host": "${reality_sni}",
        "path": "/api/v1/stream",
        "mode": "auto"
      },
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${reality_dest}",
        "xver": 0,
        "serverNames": ["${reality_sni}"],
        "privateKey": "${reality_priv}",
        "shortIds": ["${reality_shortid}"]
      }
    }
  }],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom", "settings": { "domainStrategy": "UseIP" } }
  ]
}
EOF

  docker rm -f "$container_name" 2>/dev/null || true
  docker run -d --name "$container_name" --restart unless-stopped --network host \
    -v "${install_dir}/config.json:/etc/xray/config.json:ro" \
    "${XRAY_IMAGE:-$XRAY_IMAGE_DEFAULT}" run -c /etc/xray/config.json >/dev/null
  sleep 2
  if docker ps --filter "name=$container_name" --format '{{.Names}}' | grep -q "$container_name"; then
    ok "Контейнер $container_name запущен на :$port (Reality+xhttp)"
  else
    err "Контейнер $container_name не запустился"
    return 1
  fi
  open_port_tcp "$port"
}

# WireGuard server-mode на EXIT-ноде. Сгенерит keypair, выдаст конфиг клиента (для wg-fr на entry).
deploy_bridge_wg() {
  local bridge_name="$1"
  local listen_port="${2:-51820}"
  local wg_dir="/etc/wireguard"
  local conf="${wg_dir}/wg-bridge-${bridge_name}.conf"

  # Установить wireguard если нет
  if ! command -v wg >/dev/null 2>&1; then
    step "Устанавливаю WireGuard"
    case "$(detect_pkg_mgr)" in
      apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard ;;
      dnf) dnf install -y -q wireguard-tools ;;
      yum) yum install -y -q wireguard-tools ;;
      apk) apk add --no-cache wireguard-tools ;;
      *)   err "Неизвестный пакетный менеджер, поставьте wireguard вручную"; return 1 ;;
    esac
  fi

  mkdir -p "$wg_dir"
  umask 077
  local srv_priv srv_pub psk
  srv_priv=$(wg genkey)
  srv_pub=$(echo "$srv_priv" | wg pubkey)
  psk=$(wg genpsk)

  cat > "$conf" <<EOF
[Interface]
Address = 10.88.0.1/24
ListenPort = ${listen_port}
PrivateKey = ${srv_priv}
PostUp   = iptables -t nat -A POSTROUTING -s 10.88.0.0/24 -o %i -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 10.88.0.0/24 -o %i -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
# Peer: ENTRY-нода (добавьте сюда public key entry-ноды)

EOF
  chmod 600 "$conf"

  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-bridge-wg.conf
  sysctl -p /etc/sysctl.d/99-bridge-wg.conf >/dev/null 2>&1 || true

  systemctl enable --now "wg-quick@wg-bridge-${bridge_name}" 2>/dev/null || \
    wg-quick up "wg-bridge-${bridge_name}" 2>/dev/null || true

  ok "WG-server поднят на UDP/${listen_port}, конфиг: $conf"
  open_port_udp "${listen_port}"

  printf "\n%s\n" "$(c_bold 'Параметры для подключения ENTRY-ноды (WG-клиент):')"
  printf "  Server PublicKey:  %s\n" "$srv_pub"
  printf "  Server Endpoint:   <публичный_IP_этой_ноды>:%s\n" "$listen_port"
  printf "  PresharedKey:      %s\n" "$psk"
  printf "  Address (client):  10.88.0.2/32\n"
  printf "  AllowedIPs:        0.0.0.0/0\n\n"

  # Возвращаем через stdout JSON для caller'а
  printf '{"srv_pub":"%s","psk":"%s","listen_port":%s,"conf":"%s"}\n' "$srv_pub" "$psk" "$listen_port" "$conf"
}

open_port_udp() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/udp" >/dev/null 2>&1
    ok "UFW: открыт ${port}/udp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld: открыт ${port}/udp"
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p udp --dport "$port" -j ACCEPT
    ok "iptables: открыт ${port}/udp"
  fi
}

# iperf3-сервер в Docker (порт 5201), whitelist по IP entries
deploy_iperf3_server() {
  local port="${1:-5201}"
  shift || true
  local allowed_ips=("$@")
  local container_name="bridge-iperf3"

  docker rm -f "$container_name" 2>/dev/null || true
  docker run -d --name "$container_name" --restart unless-stopped \
    -p "${port}:${port}" "$IPERF3_IMAGE" -s -p "$port" >/dev/null
  sleep 1
  if docker ps --filter "name=$container_name" --format '{{.Names}}' | grep -q "$container_name"; then
    ok "iperf3-сервер запущен на :$port"
  else
    err "iperf3-сервер не запустился"
    return 1
  fi
  if [ "${#allowed_ips[@]}" -gt 0 ]; then
    for ip in "${allowed_ips[@]}"; do
      open_port_tcp "$port" "$ip"
    done
  else
    open_port_tcp "$port"
  fi
}

# Удалить bridge-xray по имени
uninstall_bridge() {
  local bridge_name="$1"
  local container_name="bridge-xray-${bridge_name}"
  docker rm -f "$container_name" 2>/dev/null || true
  rm -rf "${BRIDGE_DIR_DEFAULT}/${bridge_name}"
  ok "Удалён контейнер $container_name и каталог конфига"
}

uninstall_iperf3() {
  docker rm -f bridge-iperf3 2>/dev/null || true
  ok "iperf3-сервер удалён"
}
