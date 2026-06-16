#!/usr/bin/env bash
# lib/entry_mode.sh — главное меню и операции ENTRY-режима.

entry_main_menu() {
  probe_history_init
  while true; do
    clear
    local hostname ip count last_probe_ts
    hostname=$(hostname 2>/dev/null || echo "?")
    ip=$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
    count=$(state_count '.entry.exit_nodes')
    last_probe_ts=$(ls -1t "$PROBE_HISTORY_DIR"/*.json 2>/dev/null | head -1 | xargs -I{} basename {} .json 2>/dev/null || echo "никогда")

    header "bridge-cli v1.0  ▸  ENTRY-режим" "Нода: ${ip:-?}   ($hostname)"
    printf "  Exit-нод в инвентаре:  %s\n" "$(c_bold "$count")"
    printf "  Последний тест:        %s\n" "$last_probe_ts"
    divider

    local creds_status
    if state_has_bridge_creds; then creds_status="$(c_grn '✓ настроены')"
    else creds_status="$(c_red '✗ не настроены')"
    fi
    printf "  Bridge credentials:    %s\n" "$creds_status"
    divider

    cat <<EOF
  [1]  Управление exit-нодами (добавить / удалить / редактировать)
  [2]  Тест ОДНОЙ exit-ноды
  [3]  Тест ВСЕХ exit-нод
  [4]  Тест скорости (iperf3)
  [5]  История тестов (последние 10 дней)
  [6]  Самодиагностика этой ENTRY-ноды
  [7]  Просмотр сгенерированных JSON-блоков по странам
  [8]  Bridge credentials (импорт/просмотр/экспорт)
  [10] ПОЛНОЕ УДАЛЕНИЕ (снести ВСЁ: bridge-cli + конфиги + history)
  ─────────────────────────────────────────────────────────────
  [9]  Обновить bridge-cli из GitHub
  [0]  Выход
EOF
    read -r -p "$(c_bold 'Выбор'): " choice
    case "$choice" in
      1) entry_manage_nodes ;;
      2) entry_probe_one ;;
      3) entry_probe_all ;;
      4) entry_iperf3 ;;
      5) entry_show_history ;;
      6) entry_self_diag ;;
      7) entry_show_generated ;;
      8) entry_credentials_menu ;;
      10) confirm_full_uninstall ;;
      9) update_from_git ;;
      0) exit 0 ;;
      *) err "Неверный выбор"; sleep 1 ;;
    esac
  done
}

# [1] Управление exit-нодами
entry_manage_nodes() {
  while true; do
    clear
    header "Inventory exit-нод"
    local count; count=$(state_count '.entry.exit_nodes')
    if [ "$count" -eq 0 ]; then
      info "Список пуст. Добавьте exit-ноду через [a]."
    else
      printf "\n  %-3s  %-15s  %-18s  %-5s  %s\n" "#" "Страна" "IP" "Порт" "Добавлено"
      printf "  %-3s  %-15s  %-18s  %-5s  %s\n" "---" "---------------" "------------------" "-----" "-------------------"
      local i=0
      while IFS= read -r row; do
        i=$((i+1))
        local cn ip port at
        cn=$(echo "$row"   | jq -r .country_name)
        ip=$(echo "$row"   | jq -r .ip)
        port=$(echo "$row" | jq -r .bridge_port)
        at=$(echo "$row"   | jq -r .added_at)
        printf "  %-3s  %-15s  %-18s  %-5s  %s\n" "$i" "$cn" "$ip" "$port" "$at"
      done < <(jq -c '.entry.exit_nodes[]' "$STATE_FILE")
    fi
    divider
    cat <<EOF
  [1]  Добавить новую exit-ноду
  [2]  Удалить exit-ноду
  [0]  Назад
EOF
    read -r -p "$(c_bold 'Выбор'): " act
    case "$act" in
      1) entry_add_node ;;
      2) entry_delete_node ;;
      0) return ;;
      *) err "Неверный выбор"; sleep 1 ;;
    esac
  done
}

entry_add_node() {
  step "Добавление новой exit-ноды"

  # 0. Убедиться что у ENTRY есть bridge_credentials
  if ! state_has_bridge_creds; then
    err "Нет общих bridge-credentials в state.json"
    info "Добавь их сначала: главное меню → '8' Bridge credentials → '1' Импортировать"
    pause; return
  fi

  # 1. Базовые параметры
  prompt "IP exit-ноды"
  local ip="$REPLY"
  [ -z "$ip" ] && { err "IP обязателен"; pause; return; }
  prompt "Код страны (de/fr/nl/us/jp...)"
  local cc; cc=$(echo "${REPLY:-}" | tr '[:upper:]' '[:lower:]')
  [ -z "$cc" ] && { err "Код страны обязателен"; pause; return; }
  local cc_upper; cc_upper=$(echo "$cc" | tr '[:lower:]' '[:upper:]')
  local cn; cn=$(country_name "$cc")
  prompt "Свободный TCP-порт на entry для inbound VLESS_${cc_upper}" "8449"
  local entry_port="$REPLY"
  local default_sni; default_sni=$(client_sni_for_country "$cc")
  prompt "SNI клиентского inbound (Reality-маскировка)" "$default_sni"
  local client_sni="$REPLY"

  local creds; creds=$(state_get_bridge_creds)
  local b; b=$(echo "$creds" | jq -c '.bridges[0]')
  local bport iport
  bport=$(echo "$b" | jq -r .port)
  iport=$(echo "$creds" | jq -r '.iperf3.port // 0')

  # 2. Soft-probe: ping и MTU (НЕ 7443 — он ещё не открыт на новой ноде)
  step "Проверка доступности по сети (ping/MTU)"
  local ping_out loss rtt
  ping_out=$(ping -c 4 -W 2 -q "$ip" 2>/dev/null || true)
  loss=$(echo "$ping_out" | awk -F', ' '/packet loss/ {gsub("% packet loss","",$3); print $3}')
  rtt=$(echo  "$ping_out" | awk -F'/' '/rtt|round-trip/ {printf "%.0fms",$5}')
  [ -z "$loss" ] && loss="?" ; [ -z "$rtt" ] && rtt="?"
  if [ "$loss" = "100" ] || [ "$loss" = "?" ]; then
    err "$ip не отвечает на ping ($loss% loss). Проверь IP и доступность."
    if ! confirm "Всё равно продолжить?" "n"; then return; fi
  else
    ok "Ping OK: loss=${loss}%, RTT=${rtt}"
  fi

  # 3. Генерируем client-side Reality keypair для inbound
  step "Генерирую уникальный client-side Reality keypair для VLESS_${cc_upper}"
  local kp client_priv client_pub client_shortid
  kp=$(gen_x25519) || { err "Не смог сгенерить keypair (нет docker?)"; pause; return; }
  client_priv=$(echo "$kp" | sed -n '1p')
  client_pub=$(echo  "$kp" | sed -n '2p')
  client_shortid=$(openssl rand -hex 8)
  ok "PrivateKey: $client_priv"
  ok "PublicKey:  $client_pub"
  ok "ShortId:    $client_shortid"

  # 4. Параметры моста (общие)
  local b_uuid b_priv b_pub b_sid b_sni b_dest
  b_uuid=$(echo "$b" | jq -r .uuid)
  b_priv=$(echo "$b" | jq -r .reality_priv)
  b_pub=$(echo  "$b" | jq -r .reality_pub)
  b_sid=$(echo  "$b" | jq -r .reality_shortid)
  b_sni=$(echo  "$b" | jq -r .reality_sni)
  b_dest=$(echo "$b" | jq -r .reality_dest)
  local b_tr; b_tr=$(echo "$b" | jq -r .transport)

  # 5. Сохранить в инвентарь
  state_append '.entry.exit_nodes' "$(jq -n \
    --arg cc "$cc" --arg cn "$cn" --arg ip "$ip" \
    --argjson bp "$bport" --argjson ip3 "$iport" --arg tr "$b_tr" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{country:$cc, country_name:$cn, ip:$ip, bridge_port:$bp, iperf3_port:$ip3, transport:$tr, added_at:$ts}')"

  # 6. Сохранить сгенерированный client-config (для повторного просмотра)
  state_append '.exit.client_configs' "$(jq -n \
    --arg cc "$cc" --arg cn "$cn" --arg entry_ip "$(_entry_ip)" --argjson entry_port "$entry_port" \
    --arg client_sni "$client_sni" --arg priv "$client_priv" --arg pub "$client_pub" --arg sid "$client_shortid" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg bname "main" --arg exit_ip "$ip" \
    '{country:$cc, country_name:$cn, entry_ip:$entry_ip, entry_port:$entry_port, exit_ip:$exit_ip,
      client_sni:$client_sni, client_priv:$priv, client_pub:$pub, client_shortid:$sid,
      created_at:$ts, bridge_name:$bname}')"

  # 7. Сгенерировать BRIDGE_CREDS base64 для команды на новой EXIT-ноде
  local creds_b64
  creds_b64=$(echo "$creds" | base64 -w0)

  # 8. Создать готовый файл с JSON-блоками
  mkdir -p "$STATE_DIR/generated"
  local out_file="$STATE_DIR/generated/${cc}.txt"
  _write_generated_blocks "$out_file" "$cc" "$cc_upper" "$cn" "$ip" "$entry_port" "$client_sni" \
    "$client_priv" "$client_pub" "$client_shortid" \
    "$b_uuid" "$b_pub" "$b_sid" "$b_sni" "$bport"

  # 9. Сохранить команды в файл (для копирования) + показать все 4 варианта в выводе
  local cmd_file="$STATE_DIR/generated/${cc}-install-cmd.sh"
  _write_install_commands "$cmd_file" "$ip" "$creds_b64"
  chmod +x "$cmd_file"

  clear
  header "✅ Добавлена exit-нода: ${cn} (${ip})"
  printf "\n"
  printf "%s\n" "$(c_bold "ШАГ 1 — Развернуть bridge-xray на новой ноде ${ip}")"
  printf "\n  %s\n" "$(c_yel '📄 Все команды также сохранены в файл:')"
  printf "      %s\n" "$(c_bold "$cmd_file")"
  printf "  %s\n" "$(c_yel '   Использовать файл — самый простой способ:')"
  printf "      %s\n"   "$(c_cyn "scp ${cmd_file} root@${ip}:/tmp/install-bridge.sh")"
  printf "      %s\n\n" "$(c_cyn "ssh root@${ip} 'bash /tmp/install-bridge.sh'")"
  printf "  %s\n\n" "$(c_yel 'Или зайди по SSH и выполни ОДНУ из команд ниже:')"
  printf "  %s\n\n" "$(c_cyn "ssh root@${ip}")"

  printf "  %s\n" "$(c_grn '▸ Вариант 1 — git clone (самый надёжный, обходит блокировки):')"
  printf "%s\n" "$(c_cyn '─────────────────────────────────────────────────────────────────────────')"
  cat <<EOF
rm -rf /tmp/bridge-src && git clone --depth 1 https://github.com/ChernOvOne/bridge.git /tmp/bridge-src
BRIDGE_CREDS='${creds_b64}' bash /tmp/bridge-src/install.sh
EOF
  printf "%s\n\n" "$(c_cyn '─────────────────────────────────────────────────────────────────────────')"

  printf "  %s\n" "$(c_grn '▸ Вариант 2 — curl | bash (быстрый, если raw.githubusercontent доступен):')"
  printf "%s\n" "$(c_cyn '─────────────────────────────────────────────────────────────────────────')"
  cat <<EOF
curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | \\
  BRIDGE_CREDS='${creds_b64}' bash
EOF
  printf "%s\n\n" "$(c_cyn '─────────────────────────────────────────────────────────────────────────')"

  printf "  %s\n" "$(c_grn '▸ Вариант 3 — двух-шаговый curl (если pipe зависает):')"
  printf "%s\n" "$(c_cyn '─────────────────────────────────────────────────────────────────────────')"
  cat <<EOF
curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh -o /tmp/inst.sh
BRIDGE_CREDS='${creds_b64}' bash /tmp/inst.sh
EOF
  printf "%s\n\n" "$(c_cyn '─────────────────────────────────────────────────────────────────────────')"

  printf "  %s\n" "$(c_grn '▸ Вариант 4 — через wget:')"
  printf "%s\n" "$(c_cyn '─────────────────────────────────────────────────────────────────────────')"
  cat <<EOF
wget -qO- https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | \\
  BRIDGE_CREDS='${creds_b64}' bash
EOF
  printf "%s\n\n" "$(c_cyn '─────────────────────────────────────────────────────────────────────────')"

  printf "%s\n" "$(c_yel 'Любой из 4 вариантов делает одно и то же:')"
  printf "  • ставит Docker (если нет)\n"
  printf "  • поднимает bridge-xray на :%s с твоими общими ключами моста\n" "$bport"
  printf "  • поднимает iperf3-server на :%s\n" "$iport"
  printf "  • открывает порты в firewall\n\n"
  printf "%s\n\n" "$(c_bold 'ШАГ 2 — После выполнения на EXIT-ноде:')"
  printf "  1. Добавь JSON-блоки в Remnawave panel.\n"
  printf "     Файл с блоками: %s\n" "$(c_bold "$out_file")"
  printf "     Посмотреть: %s\n\n" "$(c_cyn "cat $out_file")"
  printf "  2. Запусти повторный probe: главное меню → [2] Тест ОДНОЙ exit-ноды.\n\n"
  pause
}

# Helper: сохранить все 4 варианта команд в файл
_write_install_commands() {
  local file="$1" ip="$2" creds_b64="$3"
  cat > "$file" <<EOF
# Установочные команды для exit-ноды ${ip}
# Сгенерировано: $(date -u +"%Y-%m-%d %H:%M UTC")
# Содержит общие bridge-credentials в base64.
# ▸ Сначала зайди по SSH: ssh root@${ip}
# ▸ Затем выполни ОДНУ из 4 команд ниже (любую — все эквивалентны):

# ─────────────────────────────────────────────────────────────────────────
# ВАРИАНТ 1 — git clone (самый надёжный, обходит блокировки raw.githubusercontent)
# ─────────────────────────────────────────────────────────────────────────
rm -rf /tmp/bridge-src && git clone --depth 1 https://github.com/ChernOvOne/bridge.git /tmp/bridge-src
BRIDGE_CREDS='${creds_b64}' bash /tmp/bridge-src/install.sh

# ─────────────────────────────────────────────────────────────────────────
# ВАРИАНТ 2 — curl | bash (быстрый, если raw.githubusercontent доступен)
# ─────────────────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | \\
  BRIDGE_CREDS='${creds_b64}' bash

# ─────────────────────────────────────────────────────────────────────────
# ВАРИАНТ 3 — двух-шаговый curl (если pipe зависает)
# ─────────────────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh -o /tmp/inst.sh
BRIDGE_CREDS='${creds_b64}' bash /tmp/inst.sh

# ─────────────────────────────────────────────────────────────────────────
# ВАРИАНТ 4 — через wget (если curl недоступен)
# ─────────────────────────────────────────────────────────────────────────
wget -qO- https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | \\
  BRIDGE_CREDS='${creds_b64}' bash
EOF
}

# Helper: внешний IP этой ENTRY-ноды
_entry_ip() {
  curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}

# Helper: дефолтный SNI для страны
client_sni_for_country() {
  case "$1" in
    us|usa)   echo "amazon.com" ;;
    uk|gb)    echo "bbc.co.uk" ;;
    fr)       echo "wildberries.ru" ;;
    de)       echo "vk.com" ;;
    nl)       echo "ozon.ru" ;;
    pl)       echo "yandex.ru" ;;
    kz|kzz)   echo "kaspi.kz" ;;
    ru)       echo "rambler.ru" ;;
    jp)       echo "rakuten.co.jp" ;;
    sg)       echo "shopee.sg" ;;
    fi)       echo "yle.fi" ;;
    se)       echo "svt.se" ;;
    *)        echo "cloudflare.com" ;;
  esac
}

# Helper: записать готовые JSON-блоки + Host-параметры в файл
_write_generated_blocks() {
  local file="$1" cc="$2" cc_upper="$3" cn="$4" exit_ip="$5" entry_port="$6" client_sni="$7"
  local client_priv="$8" client_pub="$9" client_shortid="${10}"
  local b_uuid="${11}" b_pub="${12}" b_sid="${13}" b_sni="${14}" bridge_port="${15}"
  local entry_ip; entry_ip=$(_entry_ip)
  cat > "$file" <<EOF
╔══════════════════════════════════════════════════════════════════╗
║ Bridge-xray развёрнут на ${exit_ip}:${bridge_port}
║ Страна: ${cn} (${cc_upper})
║ Сгенерировано: $(date -u +"%Y-%m-%d %H:%M UTC")
╚══════════════════════════════════════════════════════════════════╝

━━━ В Remnawave Config Profile → "inbounds" массив ━━━
{
  "tag": "VLESS_${cc_upper}",
  "port": ${entry_port},
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {"clients": [], "decryption": "none", "flow": ""},
  "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]},
  "streamSettings": {
    "network": "tcp", "security": "reality",
    "realitySettings": {
      "dest": "${client_sni}:443", "show": false, "xver": 0,
      "shortIds": ["${client_shortid}"],
      "privateKey": "${client_priv}",
      "serverNames": ["${client_sni}"]
    }
  }
}

━━━ В "outbounds" массив ━━━
{
  "tag": "BRIDGE_${cc_upper}", "protocol": "vless",
  "settings": {"vnext": [{
    "address": "${exit_ip}", "port": ${bridge_port},
    "users": [{"id": "${b_uuid}", "flow": "xtls-rprx-vision", "encryption": "none"}]
  }]},
  "streamSettings": {
    "network": "tcp", "security": "reality",
    "realitySettings": {
      "show": false, "shortId": "${b_sid}", "spiderX": "",
      "publicKey": "${b_pub}",
      "serverName": "${b_sni}", "fingerprint": "chrome"
    }
  }
}

━━━ В "routing.rules" массив ━━━
{"type": "field", "inboundTag": ["VLESS_${cc_upper}"], "outboundTag": "BRIDGE_${cc_upper}"}

━━━ Создай Host в Remnawave UI → Hosts → New Host ━━━
  Remark:       ${cn} Тест
  Inbound:      VLESS_${cc_upper}
  Address:      ${entry_ip}
  Port:         ${entry_port}
  SNI:          ${client_sni}
  PublicKey:    ${client_pub}
  ShortId:      ${client_shortid}
  Fingerprint:  chrome
  Security:     reality
  Network:      tcp
  Flow:         (пусто)
  Mux:          OFF (обязательно)
EOF
}

entry_delete_node() {
  local count; count=$(state_count '.entry.exit_nodes')
  if [ "$count" -eq 0 ]; then return; fi
  local items=()
  while IFS= read -r row; do
    local cn ip
    cn=$(echo "$row" | jq -r .country_name)
    ip=$(echo "$row" | jq -r .ip)
    items+=("$cn — $ip")
  done < <(jq -c '.entry.exit_nodes[]' "$STATE_FILE")
  items+=("← Отмена")
  menu_select "Какую ноду удалить?" "${items[@]}"
  if [ "$MENU_REPLY" -eq "$((${#items[@]} - 1))" ]; then return; fi
  if confirm "Точно удалить '${items[$MENU_REPLY]}'?" "n"; then
    state_delete_at '.entry.exit_nodes' "$MENU_REPLY"
    ok "Удалено"
  fi
  pause
}

# [2] Тест одной
entry_probe_one() {
  header "Тест одной exit-ноды"
  local count; count=$(state_count '.entry.exit_nodes')
  if [ "$count" -eq 0 ]; then
    info "Список пуст. Сначала добавьте через [1]."
    pause; return
  fi
  local items=()
  while IFS= read -r row; do
    items+=("$(echo "$row" | jq -r '"\(.country_name) — \(.ip)"')")
  done < <(jq -c '.entry.exit_nodes[]' "$STATE_FILE")
  menu_select "Какую ноду тестировать?" "${items[@]}"
  local node
  node=$(jq -c ".entry.exit_nodes[$MENU_REPLY]" "$STATE_FILE")
  local ip port
  ip=$(echo "$node"   | jq -r .ip)
  port=$(echo "$node" | jq -r .bridge_port)

  print_probe_header
  local res; res=$(probe_one "$ip" "$port" "max.ru")
  print_probe_row "$res"
  save_probe_history "[$res]"
  pause
}

# [3] Тест всех
entry_probe_all() {
  header "Тест всех exit-нод"
  local count; count=$(state_count '.entry.exit_nodes')
  if [ "$count" -eq 0 ]; then info "Список пуст"; pause; return; fi

  print_probe_header with_cn
  local results="["
  local first=1
  while IFS= read -r row; do
    local ip port cc
    ip=$(echo "$row"   | jq -r .ip)
    port=$(echo "$row" | jq -r .bridge_port)
    cc=$(echo "$row"   | jq -r .country)
    local res; res=$(probe_one "$ip" "$port" "max.ru")
    print_probe_row "$res" "$cc"
    if [ "$first" -eq 1 ]; then results="$results$res"; first=0
    else results="$results,$res"; fi
  done < <(jq -c '.entry.exit_nodes[]' "$STATE_FILE")
  results="$results]"
  save_probe_history "$results"
  pause
}

# [4] iperf3-тест
entry_iperf3() {
  header "Тест throughput (iperf3)"
  local count; count=$(state_count '.entry.exit_nodes')
  if [ "$count" -eq 0 ]; then info "Список пуст"; pause; return; fi
  local items=()
  while IFS= read -r row; do
    items+=("$(echo "$row" | jq -r '"\(.country_name) — \(.ip)"')")
  done < <(jq -c '.entry.exit_nodes[]' "$STATE_FILE")
  menu_select "Какую ноду тестировать?" "${items[@]}"
  local node
  node=$(jq -c ".entry.exit_nodes[$MENU_REPLY]" "$STATE_FILE")
  local ip port
  ip=$(echo "$node"   | jq -r .ip)
  port=$(echo "$node" | jq -r .iperf3_port)
  if [ "$port" = "0" ] || [ -z "$port" ]; then
    err "Для этой ноды не настроен iperf3-порт"
    pause; return
  fi
  iperf3_test "$ip" "$port"
  pause
}

# [5] История тестов
entry_show_history() {
  header "История тестов (последние 10 дней)"
  local files
  files=$(ls -1t "$PROBE_HISTORY_DIR"/*.json 2>/dev/null || true)
  if [ -z "$files" ]; then
    info "История пуста"
    pause; return
  fi
  local items=()
  local file_arr=()
  while IFS= read -r f; do
    items+=("$(basename "$f" .json)")
    file_arr+=("$f")
  done <<< "$files"
  items+=("← Назад")
  menu_select "Выберите запись:" "${items[@]}"
  if [ "$MENU_REPLY" -eq "$((${#items[@]} - 1))" ]; then return; fi
  local picked="${file_arr[$MENU_REPLY]}"
  print_probe_header
  while IFS= read -r row; do
    print_probe_row "$row"
  done < <(jq -c '.[]' "$picked")
  pause
}

# [6] Самодиагностика ENTRY
entry_self_diag() {
  header "Самодиагностика ENTRY-ноды"
  step "Сетевые интерфейсы:"
  ip -br addr 2>/dev/null | head -20
  step "Маршруты по-умолчанию:"
  ip route 2>/dev/null | head -10
  step "MSS-clamping (iptables):"
  iptables-save 2>/dev/null | grep -E 'TCPMSS|clamp' | head -10 || echo "  (нет)"
  step "nftables MSS:"
  nft list ruleset 2>/dev/null | grep -i mss | head -10 || echo "  (нет)"
  step "WireGuard интерфейсы:"
  wg show interfaces 2>/dev/null || echo "  (нет)"
  step "Docker-контейнеры:"
  docker ps --format '  {{.Names}} — {{.Status}} — {{.Ports}}' 2>/dev/null | head -10 || echo "  Docker не установлен"
  step "Загрузка системы:"
  uptime
  pause
}

# [7] Сгенерировать xray-блоки
# [7] Просмотр сгенерированных блоков по странам (файлы etc/generated/<cc>.txt)
entry_show_generated() {
  header "Сгенерированные JSON-блоки по странам"
  local gendir="$STATE_DIR/generated"
  mkdir -p "$gendir"
  local files; files=("$gendir"/*.txt)
  if [ ! -e "${files[0]}" ]; then
    info "Файлов нет. Они создаются автоматически при добавлении exit-ноды через [1]."
    pause; return
  fi
  local items=()
  for f in "${files[@]}"; do
    items+=("$(basename "$f" .txt)")
  done
  items+=("← Назад")
  menu_select "Выберите страну для просмотра блоков:" "${items[@]}"
  local idx="$MENU_REPLY"
  if [ "$idx" -eq "$((${#items[@]} - 1))" ]; then return; fi
  clear
  cat "$gendir/${items[$idx]}.txt"
  echo
  pause
}

# [8] Bridge credentials submenu
entry_credentials_menu() {
  while true; do
    clear
    header "Bridge credentials"
    if state_has_bridge_creds; then
      local b; b=$(state_get_bridge_creds | jq -c '.bridges[0]')
      printf "  Статус:   %s\n" "$(c_grn 'настроены')"
      printf "  UUID:     %s\n" "$(echo "$b" | jq -r .uuid)"
      printf "  Pub-key:  %s\n" "$(echo "$b" | jq -r .reality_pub)"
      printf "  ShortId:  %s\n" "$(echo "$b" | jq -r .reality_shortid)"
      printf "  SNI:      %s\n" "$(echo "$b" | jq -r .reality_sni)"
      printf "  Port:     %s\n" "$(echo "$b" | jq -r .port)"
    else
      printf "  Статус:   %s\n" "$(c_red 'не настроены')"
      printf "  %s\n" "Bridge-credentials нужны для добавления новых exit-нод одной"
      printf "  %s\n" "командой. Это общие UUID + Reality-keys которые используются"
      printf "  %s\n" "на всех твоих exit-нодах одновременно."
    fi
    divider
    cat <<EOF
  [1]  Импортировать из base64-строки (от другой ноды)
  [2]  Импортировать вводом полей вручную
  [3]  Экспорт (base64-строка для другой ENTRY)
  [4]  Удалить
  [0]  Назад
EOF
    read -r -p "$(c_bold 'Выбор'): " act
    case "$act" in
      1) entry_creds_import_b64 ;;
      2) entry_creds_import_manual ;;
      3) entry_creds_export ;;
      4) entry_creds_delete ;;
      0) return ;;
      *) err "Неверный выбор"; sleep 1 ;;
    esac
  done
}

entry_creds_import_b64() {
  step "Импорт credentials из base64-строки"
  printf "Вставьте base64-строку (одна строка, заканчивается Enter):\n"
  local b64
  read -r b64
  local decoded
  decoded=$(echo "$b64" | base64 -d 2>/dev/null)
  if [ -z "$decoded" ] || ! echo "$decoded" | jq -e '.bridges[0].uuid' >/dev/null 2>&1; then
    err "Не валидный base64 или не валидный JSON структуры credentials"
    pause; return
  fi
  state_set_bridge_creds "$decoded"
  ok "Bridge-credentials импортированы"
  pause
}

entry_creds_import_manual() {
  step "Ввод credentials вручную"
  prompt "BRIDGE_UUID"
  local uuid="$REPLY"
  prompt "Reality PrivateKey (приватник моста, нужен только если деплоим bridge с этой ноды; иначе пробел)"
  local priv="${REPLY:- }"
  prompt "Reality PublicKey (публичник моста — обязателен)"
  local pub="$REPLY"
  prompt "Reality ShortId моста" "61dfff54"
  local sid="$REPLY"
  prompt "Reality SNI моста" "max.ru"
  local sni="$REPLY"
  prompt "Reality dest моста" "max.ru:443"
  local dest="$REPLY"
  prompt "Bridge-port" "7443"
  local port="$REPLY"
  if [ -z "$uuid" ] || [ -z "$pub" ]; then
    err "UUID и PublicKey обязательны"
    pause; return
  fi
  local creds
  creds=$(jq -n --arg uuid "$uuid" --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" \
                --arg sni "$sni" --arg dest "$dest" --argjson port "$port" \
    '{bridges:[{name:"main",port:$port,transport:"reality",uuid:$uuid,reality_priv:$priv,reality_pub:$pub,reality_shortid:$sid,reality_sni:$sni,reality_dest:$dest}],
      iperf3:{enabled:true,port:5201,allowed_ips:[]}}')
  state_set_bridge_creds "$creds"
  ok "Bridge-credentials сохранены"
  pause
}

entry_creds_export() {
  if ! state_has_bridge_creds; then err "Сначала импортируйте credentials"; pause; return; fi
  local b64
  b64=$(state_get_bridge_creds | base64 -w0)
  clear
  header "Экспорт bridge-credentials"
  printf "\n%s\n\n" "$(c_yel 'Скопируйте эту строку и передайте на другую ENTRY-ноду (br → [8] → [1]):')"
  printf "%s\n" "$(c_cyn '─────────────────────────────────────────────────────────────────────────')"
  printf "%s\n" "$b64"
  printf "%s\n\n" "$(c_cyn '─────────────────────────────────────────────────────────────────────────')"
  pause
}

entry_creds_delete() {
  if ! confirm "Точно удалить bridge-credentials?" "n"; then return; fi
  state_set '.entry.bridge_credentials = null'
  ok "Удалено"
  pause
}
