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

    cat <<EOF
  [1]  Управление exit-нодами (добавить / удалить / редактировать)
  [2]  Тест ОДНОЙ exit-ноды
  [3]  Тест ВСЕХ exit-нод
  [4]  Тест скорости (iperf3)
  [5]  История тестов (последние 10 дней)
  [6]  Самодиагностика этой ENTRY-ноды
  [7]  Сгенерировать xray-блоки для Remnawave
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
      7) entry_generate_blocks ;;
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
  prompt "IP exit-ноды"
  local ip="$REPLY"
  [ -z "$ip" ] && { err "IP обязателен"; pause; return; }
  prompt "Код страны (de/fr/nl/us/...)"
  local cc; cc=$(echo "${REPLY:-}" | tr '[:upper:]' '[:lower:]')
  [ -z "$cc" ] && { err "Код страны обязателен"; pause; return; }
  prompt "Порт bridge-xray" "7443"
  local bport="$REPLY"
  prompt "Порт iperf3-сервера (0 если не используется)" "5201"
  local iport="$REPLY"

  local transports=("reality" "xhttp" "wg")
  menu_select "Тип транспорта на этой exit-ноде:" "Reality+TCP+Vision" "Reality+xhttp" "WireGuard"
  local tr="${transports[$MENU_REPLY]}"

  local cn; cn=$(country_name "$cc")

  step "Запускаю probe (займёт ~10 сек)"
  local res
  res=$(probe_one "$ip" "$bport" "max.ru")
  print_probe_header
  print_probe_row "$res"
  local verdict
  verdict=$(echo "$res" | jq -r .verdict)
  if [ "$verdict" = "unreachable" ]; then
    if ! confirm "Нода НЕ доступна. Всё равно добавить?" "n"; then
      pause; return
    fi
  fi

  state_append '.entry.exit_nodes' "$(jq -n \
    --arg cc "$cc" --arg cn "$cn" --arg ip "$ip" \
    --argjson bp "$bport" --argjson ip3 "$iport" --arg tr "$tr" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{country:$cc, country_name:$cn, ip:$ip, bridge_port:$bp, iperf3_port:$ip3, transport:$tr, added_at:$ts}')"
  ok "Добавлено: $cn ($ip)"
  pause
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

  print_probe_header
  local results="["
  local first=1
  while IFS= read -r row; do
    local ip port cn
    ip=$(echo "$row"   | jq -r .ip)
    port=$(echo "$row" | jq -r .bridge_port)
    cn=$(echo "$row"   | jq -r .country_name)
    local res; res=$(probe_one "$ip" "$port" "max.ru")
    # Добавим название страны в строку перед IP
    printf "  %s " "$(c_cyn "$cn")"
    print_probe_row "$res"
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
entry_generate_blocks() {
  header "Генерация xray-блоков для Remnawave"
  local count; count=$(state_count '.entry.exit_nodes')
  if [ "$count" -eq 0 ]; then
    info "Сначала добавьте exit-ноды через [1]."
    pause; return
  fi
  cat <<EOF

  ${C_YEL}Внимание:${C_RST} это работает только для exit-нод, развёрнутых через bridge-cli.
  Нам нужен PublicKey моста, который вы получили при создании ноды через
  пункт «Подключить вторую ENTRY-ноду» (вариант 'изолированный') или
  при первичном init exit-ноды.

  Введите параметры моста (одинаковые для всех узлов если общий мост):

EOF
  prompt "BRIDGE_UUID (общий UUID моста)"
  local b_uuid="$REPLY"
  prompt "BRIDGE_PUBLIC_KEY (Reality public key моста)"
  local b_pub="$REPLY"
  prompt "BRIDGE_SHORTID (Reality short ID моста)" "61dfff54"
  local b_sid="$REPLY"
  prompt "BRIDGE_SNI" "max.ru"
  local b_sni="$REPLY"

  while IFS= read -r row; do
    local ip cc cn port
    ip=$(echo "$row" | jq -r .ip)
    cc=$(echo "$row" | jq -r .country | tr '[:lower:]' '[:upper:]')
    cn=$(echo "$row" | jq -r .country_name)
    port=$(echo "$row" | jq -r .bridge_port)
    printf "\n%s\n" "$(c_bold "▸ BRIDGE_${cc}  ($cn — $ip:$port)")"
    jq -n --arg tag "BRIDGE_${cc}" --arg addr "$ip" --argjson port "$port" \
      --arg uuid "$b_uuid" --arg pub "$b_pub" --arg sid "$b_sid" --arg sni "$b_sni" \
      '{
        tag:$tag, protocol:"vless",
        settings:{vnext:[{address:$addr,port:$port,users:[{id:$uuid,flow:"xtls-rprx-vision",encryption:"none"}]}]},
        streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,shortId:$sid,spiderX:"",publicKey:$pub,serverName:$sni,fingerprint:"chrome"}}
      }'
    printf "\n%s\n" "$(c_bold "▸ routing rule для VLESS_${cc} → BRIDGE_${cc}")"
    jq -n --arg ib "VLESS_${cc}" --arg ob "BRIDGE_${cc}" '{type:"field",inboundTag:[$ib],outboundTag:$ob}'
  done < <(jq -c '.entry.exit_nodes[]' "$STATE_FILE")

  pause
}
