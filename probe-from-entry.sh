#!/usr/bin/env bash
# probe-from-entry.sh — проверка списка IP с entry-ноды (RU/Aeza/etc):
# ping/loss/latency, доступность bridge-порта 7443, TLS-handshake к Reality, MTU.
#
# Использование:
#   bash <(curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/probe-from-entry.sh) \
#       77.110.116.16 45.12.133.36 206.206.103.163
#
# Опционально:
#   BRIDGE_PORT=7443         (порт bridge-xray на foreign-нодах)
#   BRIDGE_REALITY_SNI=max.ru (SNI, под которым замаскирован Reality)
#   PING_COUNT=10
#   IPERF=1                  (если =1 и iperf3 установлен — пробует throughput-test, нужен iperf3-сервер на foreign)

set -uo pipefail

BRIDGE_PORT="${BRIDGE_PORT:-7443}"
BRIDGE_REALITY_SNI="${BRIDGE_REALITY_SNI:-max.ru}"
PING_COUNT="${PING_COUNT:-10}"
IPERF="${IPERF:-0}"

[ $# -lt 1 ] && {
  cat <<EOF
❌ Usage: $0 <ip1> [ip2] [ip3] ...
Например:
  $0 77.110.116.16 45.12.133.36 62.60.247.142
EOF
  exit 1
}

# Цвета
bold() { printf "\033[1m%s\033[0m" "$1"; }
green(){ printf "\033[1;32m%s\033[0m" "$1"; }
red()  { printf "\033[1;31m%s\033[0m" "$1"; }
yel()  { printf "\033[1;33m%s\033[0m" "$1"; }

echo
printf "%-18s  %-6s  %-9s  %-6s  %-9s  %-5s  %s\n" "IP" "loss" "RTT(avg)" "$BRIDGE_PORT" "Reality" "MTU" "Verdict"
printf "%-18s  %-6s  %-9s  %-6s  %-9s  %-5s  %s\n" "------------------" "------" "---------" "------" "---------" "-----" "-----------"

probe_one() {
  local IP="$1"
  local LOSS RTT TCP TLS MTU VERDICT TCPRESULT TLSRESULT

  # PING (loss + rtt)
  PING_OUT=$(ping -c "$PING_COUNT" -W 2 -q "$IP" 2>/dev/null || true)
  LOSS=$(echo "$PING_OUT" | awk -F', ' '/packet loss/ {gsub("% packet loss","",$3); print $3}')
  RTT=$(echo  "$PING_OUT" | awk -F'/' '/rtt|round-trip/ {printf "%.0fms",$5}')
  [ -z "$LOSS" ] && LOSS="—"
  [ -z "$RTT" ]  && RTT="—"

  # TCP connect 7443
  if timeout 4 bash -c "</dev/tcp/$IP/$BRIDGE_PORT" 2>/dev/null; then
    TCP=$(green OK)
    TCPRESULT=ok
  else
    TCP=$(red FAIL)
    TCPRESULT=fail
  fi

  # TLS/Reality (openssl, проверяет что отвечает с TLS-CN=$BRIDGE_REALITY_SNI)
  if [ "$TCPRESULT" = ok ]; then
    TLS_OUT=$(timeout 5 openssl s_client -connect "$IP:$BRIDGE_PORT" -servername "$BRIDGE_REALITY_SNI" -tls1_3 < /dev/null 2>&1 || true)
    if echo "$TLS_OUT" | grep -q "CN=$BRIDGE_REALITY_SNI"; then
      TLS=$(green OK)
      TLSRESULT=ok
    elif echo "$TLS_OUT" | grep -q "CONNECTED"; then
      TLS=$(yel "WRONG_CN")
      TLSRESULT=wrong
    else
      TLS=$(red FAIL)
      TLSRESULT=fail
    fi
  else
    TLS="—"
    TLSRESULT=skip
  fi

  # MTU discovery (упрощённо: tracepath one hop)
  if command -v tracepath >/dev/null 2>&1; then
    MTU=$(tracepath -n -m 5 "$IP" 2>/dev/null | grep -oP 'pmtu \K\d+' | tail -1)
  fi
  [ -z "${MTU:-}" ] && MTU="?"

  # Verdict
  if [ "$TCPRESULT" = ok ] && [ "$TLSRESULT" = ok ]; then
    LOSS_NUM=$(echo "$LOSS" | grep -oP '^\d+' || echo 0)
    if [ "$LOSS_NUM" -ge 10 ]; then
      VERDICT=$(yel "⚠ packet loss")
    else
      VERDICT=$(green "✅ excellent")
    fi
  elif [ "$TCPRESULT" = fail ]; then
    VERDICT=$(red "❌ unreachable")
  elif [ "$TLSRESULT" = wrong ]; then
    VERDICT=$(yel "⚠ bridge ≠ ${BRIDGE_REALITY_SNI}")
  else
    VERDICT=$(red "❌ no Reality")
  fi

  printf "%-18s  %-6s  %-9s  %-15s  %-18s  %-5s  %b\n" \
         "$IP" "$LOSS" "$RTT" "$TCP" "$TLS" "$MTU" "$VERDICT"

  # iperf3 опционально
  if [ "$IPERF" = "1" ] && [ "$TCPRESULT" = ok ] && command -v iperf3 >/dev/null 2>&1; then
    printf "                                       throughput: "
    SPEED=$(timeout 12 iperf3 -c "$IP" -t 5 -f m 2>/dev/null | awk '/receiver/ {print $7, $8}')
    [ -n "$SPEED" ] && echo "$SPEED" || echo "iperf3 server недоступен"
  fi
}

for IP in "$@"; do
  probe_one "$IP"
done

echo
echo "Подсказки:"
echo "  ❌ unreachable     — TCP/${BRIDGE_PORT} не отвечает (firewall/TSPU/нода не активна)"
echo "  ⚠ wrong CN         — порт открыт, но не наш bridge-xray (другой сервис)"
echo "  ❌ no Reality      — TLS handshake провалился"
echo "  ⚠ packet loss      — нода достижима, но сеть нестабильна (избегать)"
echo "  ✅ excellent       — годится для production"
echo
