#!/usr/bin/env bash
# lib/probe.sh — сетевые тесты exit-нод с entry-стороны.

PROBE_HISTORY_DIR="${BRIDGE_CLI_HOME:-/opt/bridge-cli}/etc/probe-history"
PROBE_RETENTION_DAYS=10

probe_history_init() {
  mkdir -p "$PROBE_HISTORY_DIR"
  # Очистка старых файлов (>10 дней)
  find "$PROBE_HISTORY_DIR" -type f -name '*.json' -mtime "+$PROBE_RETENTION_DAYS" -delete 2>/dev/null || true
}

# probe_one IP [bridge_port] [reality_sni] → echo JSON-объект с результатами
probe_one() {
  local ip="$1"
  local bridge_port="${2:-7443}"
  local reality_sni="${3:-max.ru}"
  local ping_count="${PING_COUNT:-10}"

  local loss="—" rtt="—" tcp_ok=0 tls_ok=0 tls_reason="" mtu="—" verdict=""

  # ping
  local ping_out
  ping_out=$(ping -c "$ping_count" -W 2 -q "$ip" 2>/dev/null || true)
  if [ -n "$ping_out" ]; then
    loss=$(echo "$ping_out" | awk -F', ' '/packet loss/ {gsub("% packet loss","",$3); print $3}')
    rtt=$(echo  "$ping_out" | awk -F'/' '/rtt|round-trip/ {printf "%.0fms",$5}')
    [ -z "$loss" ] && loss="—"
    [ -z "$rtt" ]  && rtt="—"
  fi

  # TCP-connect
  if timeout 4 bash -c "</dev/tcp/$ip/$bridge_port" 2>/dev/null; then
    tcp_ok=1
  fi

  # TLS Reality
  if [ "$tcp_ok" -eq 1 ]; then
    local tls_out
    tls_out=$(timeout 5 openssl s_client -connect "${ip}:${bridge_port}" \
                -servername "$reality_sni" -tls1_3 < /dev/null 2>&1 || true)
    if echo "$tls_out" | grep -q "CN *= *${reality_sni}"; then
      tls_ok=1
    elif echo "$tls_out" | grep -q "CONNECTED"; then
      tls_ok=0; tls_reason="wrong_cn"
    else
      tls_ok=0; tls_reason="fail"
    fi
  fi

  # MTU
  if command -v tracepath >/dev/null 2>&1; then
    mtu=$(tracepath -n -m 5 "$ip" 2>/dev/null | grep -oP 'pmtu \K\d+' | tail -1)
  fi
  [ -z "$mtu" ] && mtu="—"

  # Verdict
  local loss_num
  loss_num=$(echo "$loss" | grep -oP '^\d+' || echo 0)
  if [ "$tcp_ok" -eq 0 ]; then
    verdict="unreachable"
  elif [ "$tls_ok" -eq 0 ] && [ "$tls_reason" = "wrong_cn" ]; then
    verdict="wrong_sni"
  elif [ "$tls_ok" -eq 0 ]; then
    verdict="no_reality"
  elif [ "$loss_num" -ge 10 ]; then
    verdict="packet_loss"
  else
    verdict="excellent"
  fi

  jq -n \
    --arg ip "$ip" --arg loss "$loss" --arg rtt "$rtt" \
    --argjson tcp_ok "$tcp_ok" --argjson tls_ok "$tls_ok" \
    --arg tls_reason "$tls_reason" --arg mtu "$mtu" --arg verdict "$verdict" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{ip:$ip, loss:$loss, rtt:$rtt, tcp_ok:$tcp_ok, tls_ok:$tls_ok, tls_reason:$tls_reason, mtu:$mtu, verdict:$verdict, timestamp:$ts}'
}

# Красивая печать одной строки результата
print_probe_row() {
  local row_json="$1"
  local cn_prefix="${2:-}"
  local ip loss rtt tcp tls mtu verdict
  ip=$(echo "$row_json"      | jq -r .ip)
  loss=$(echo "$row_json"    | jq -r .loss)
  rtt=$(echo "$row_json"     | jq -r .rtt)
  tcp=$(echo "$row_json"     | jq -r '.tcp_ok | if . == 1 then "OK" else "FAIL" end')
  local tls_ok tls_reason
  tls_ok=$(echo "$row_json" | jq -r .tls_ok)
  tls_reason=$(echo "$row_json" | jq -r .tls_reason)
  if [ "$tls_ok" = "1" ]; then tls="OK"
  elif [ "$tls_reason" = "wrong_cn" ]; then tls="WRONG_CN"
  elif [ "$tls_reason" = "fail" ]; then tls="FAIL"
  else tls="—"; fi
  mtu=$(echo "$row_json" | jq -r .mtu)
  verdict=$(echo "$row_json" | jq -r .verdict)

  local v_str
  case "$verdict" in
    excellent)   v_str="$(c_grn '✅ отлично')" ;;
    packet_loss) v_str="$(c_yel '⚠ потери')" ;;
    wrong_sni)   v_str="$(c_yel '⚠ чужой Reality')" ;;
    no_reality)  v_str="$(c_red '✗ нет Reality')" ;;
    unreachable) v_str="$(c_red '✗ недоступен')" ;;
    *)           v_str="$verdict" ;;
  esac

  local tcp_c
  if [ "$tcp" = "OK" ]; then tcp_c="$(c_grn OK)"; else tcp_c="$(c_red FAIL)"; fi
  local tls_c
  if [ "$tls" = "OK" ]; then tls_c="$(c_grn OK)"
  elif [ "$tls" = "—" ]; then tls_c="—"
  else tls_c="$(c_red "$tls")"; fi

  if [ -n "$cn_prefix" ]; then
    # Префикс страны фиксированной ширины (3 ascii char + скобки = 5 чар)
    local cc_padded
    cc_padded=$(printf "[%-3s]" "$(echo "$cn_prefix" | tr '[:lower:]' '[:upper:]')")
    printf "  %s  %-18s  %-5s  %-7s  %-12s  %-15s  %-5s  %b\n" \
      "$cc_padded" "$ip" "$loss" "$rtt" "$tcp_c" "$tls_c" "$mtu" "$v_str"
  else
    printf "  %-18s  %-5s  %-7s  %-12s  %-15s  %-5s  %b\n" \
      "$ip" "$loss" "$rtt" "$tcp_c" "$tls_c" "$mtu" "$v_str"
  fi
}

print_probe_header() {
  local with_cn="${1:-}"
  if [ "$with_cn" = "with_cn" ]; then
    printf "\n  %-5s  %-18s  %-5s  %-7s  %-5s  %-9s  %-5s  %s\n" \
      "Стр." "IP" "loss" "RTT" "Порт" "Reality" "MTU" "Вердикт"
    printf "  %-5s  %-18s  %-5s  %-7s  %-5s  %-9s  %-5s  %s\n" \
      "-----" "------------------" "-----" "-------" "-----" "---------" "-----" "----------"
  else
    printf "\n  %-18s  %-5s  %-7s  %-5s  %-9s  %-5s  %s\n" \
      "IP" "loss" "RTT" "Порт" "Reality" "MTU" "Вердикт"
    printf "  %-18s  %-5s  %-7s  %-5s  %-9s  %-5s  %s\n" \
      "------------------" "-----" "-------" "-----" "---------" "-----" "----------"
  fi
}

# Сохранить результаты в файл истории
save_probe_history() {
  local json="$1"
  local ts; ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  local file="${PROBE_HISTORY_DIR}/${ts}.json"
  echo "$json" > "$file"
  info "Сохранено: $file"
}

# iperf3-тест против exit-ноды
iperf3_test() {
  local ip="$1"; local port="${2:-5201}"
  if ! command -v iperf3 >/dev/null 2>&1; then
    err "iperf3 не установлен на этой ноде. Установите: apt install iperf3"
    return 1
  fi
  step "Тест throughput против $ip:$port (10 сек)"
  local res
  res=$(timeout 15 iperf3 -c "$ip" -p "$port" -t 10 -f m 2>&1)
  if echo "$res" | grep -q "iperf Done"; then
    local down up
    down=$(echo "$res" | awk '/receiver/ {print $7, $8}' | head -1)
    up=$(echo   "$res" | awk '/sender/   {print $7, $8}' | head -1)
    ok "Скорость: ↓ $down  ↑ $up"
  else
    err "iperf3 не смог подключиться (нет сервера? firewall?)"
    echo "$res" | tail -5
  fi
}
