#!/usr/bin/env bash
# lib/exit_mode.sh — главное меню и операции EXIT-режима.

GENERATED_DIR="${BRIDGE_CLI_HOME:-/opt/bridge-cli}/etc/generated"

exit_mode_init() {
  mkdir -p "$GENERATED_DIR"
}

# Главное меню
exit_main_menu() {
  exit_mode_init
  while true; do
    clear
    local hostname ip role bridges count container status iperf3_on
    hostname=$(hostname 2>/dev/null || echo "?")
    ip=$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
    bridges=$(state_count '.exit.bridges')
    iperf3_on=$(state_get '.exit.iperf3.enabled')
    header "bridge-cli v1.0  ▸  EXIT-режим" "Нода: ${ip:-?}   ($hostname)"
    printf "  Мостов развёрнуто:     %s\n" "$(c_bold "$bridges")"
    if [ "$bridges" -gt 0 ]; then
      while IFS= read -r b; do
        local bname bport btr
        bname=$(echo "$b" | jq -r .name)
        bport=$(echo "$b" | jq -r .port)
        btr=$(echo "$b"   | jq -r .transport)
        container="bridge-xray-${bname}"
        if docker ps --filter "name=$container" --format '{{.Names}}' 2>/dev/null | grep -q "$container"; then
          status="$(c_grn 'работает')"
        else
          status="$(c_red 'остановлен')"
        fi
        printf "    %s «%s» — порт %s, транспорт %s, статус: %s\n" "$(c_cyn '•')" "$bname" "$bport" "$btr" "$status"
      done < <(jq -c '.exit.bridges[]' "$STATE_FILE" 2>/dev/null)
    fi
    printf "  iperf3-сервер:         %s\n" "$([ "$iperf3_on" = "true" ] && c_grn включён || c_yel выключен)"
    printf "  Стран в подписке:      %s\n" "$(state_count '.exit.client_configs')"
    divider

    printf "\n  %s\n" "$(c_yel 'ℹ Добавление новых стран в подписку делается с ENTRY-ноды')"
    printf "  %s\n\n" "$(c_yel '   (br на Aeza → [1] Управление exit-нодами → [1] Добавить)')"
    cat <<EOF
  [1]  Тест моста (TLS, порт, скорость)
  [2]  Live-логи bridge-xray
  [3]  Перезапустить bridge-xray
  [4]  Экспорт credentials (для разворачивания на другой EXIT-ноде)
  [5]  Подключить вторую ENTRY-ноду (multi-tenant мост)
  [6]  Переустановить / удалить ОДИН мост
  [7]  ПОЛНОЕ УДАЛЕНИЕ (снести ВСЁ: bridge-cli + контейнеры + конфиги)
  ─────────────────────────────────────────────────────────────
  [9]  Обновить bridge-cli из GitHub
  [0]  Выход
EOF
    read -r -p "$(c_bold 'Выбор'): " choice
    case "$choice" in
      1) exit_test_bridge ;;
      2) exit_live_logs ;;
      3) exit_restart_bridge ;;
      4) exit_export_creds ;;
      5) exit_add_entry_node ;;
      6) exit_uninstall_menu ;;
      7) confirm_full_uninstall ;;
      9) update_from_git ;;
      0) exit 0 ;;
      *) err "Неверный выбор"; sleep 1 ;;
    esac
  done
}

# [1] Добавить новую страну в подписку
exit_add_country() {
  header "Добавление новой страны" "Сгенерируем уникальный client-side Reality keypair"

  # Выбор моста (если несколько)
  local bridges_count
  bridges_count=$(state_count '.exit.bridges')
  if [ "$bridges_count" -eq 0 ]; then
    err "Нет ни одного развёрнутого моста. Сначала установите EXIT через init."
    pause; return
  fi

  local bridge_name
  if [ "$bridges_count" -eq 1 ]; then
    bridge_name=$(state_get '.exit.bridges[0].name')
  else
    local names=()
    while IFS= read -r n; do names+=("$n"); done < <(jq -r '.exit.bridges[].name' "$STATE_FILE")
    menu_select "К какому мосту привязать эту страну?" "${names[@]}"
    bridge_name="${names[$MENU_REPLY]}"
  fi

  local bridge_json
  bridge_json=$(jq -c --arg n "$bridge_name" '.exit.bridges[] | select(.name == $n)' "$STATE_FILE")
  local bridge_port reality_sni reality_shortid bridge_uuid bridge_pub
  bridge_port=$(echo "$bridge_json" | jq -r .port)
  reality_sni=$(echo "$bridge_json" | jq -r .reality_sni)
  reality_shortid=$(echo "$bridge_json" | jq -r .reality_shortid)
  bridge_uuid=$(echo "$bridge_json" | jq -r .uuid)
  bridge_pub=$(echo "$bridge_json" | jq -r .reality_pub)

  printf "\n"
  local cc
  prompt "Код страны (us/uk/jp/fr/de/...)"
  cc=$(echo "${REPLY:-}" | tr '[:upper:]' '[:lower:]')
  if [ -z "$cc" ]; then
    err "Код страны обязателен"
    pause; return
  fi

  local cc_upper cc_name
  cc_upper=$(echo "$cc" | tr '[:lower:]' '[:upper:]')
  cc_name=$(country_name "$cc")

  printf "\n%s\n" "$(c_yel 'Безопасные порты на ENTRY-ноде (Россия часто пропускает):')"
  printf "  %s 443, 2087, 2083, 8443, 8447, 8448, 8449, 2096\n" "$(c_cyn '•')"
  printf "  %s избегайте 2053, 445, всё что выше 50000\n\n" "$(c_red '✗')"

  prompt "IP вашей ENTRY-ноды (Aeza/RU)"
  local entry_ip="$REPLY"
  [ -z "$entry_ip" ] && { err "IP обязателен"; pause; return; }

  prompt "Свободный TCP-порт на ENTRY для VLESS_${cc_upper}" "8449"
  local entry_port="$REPLY"

  local default_sni
  default_sni=$(sni_for_country "$cc")
  prompt "SNI клиентского inbound (домен для Reality-маскировки)" "$default_sni"
  local client_sni="$REPLY"

  step "Генерирую client-side Reality keypair"
  local keypair priv pub
  keypair=$(gen_x25519) || { pause; return; }
  priv=$(echo "$keypair" | sed -n '1p')
  pub=$(echo  "$keypair" | sed -n '2p')
  local client_shortid
  client_shortid=$(gen_shortid_16)
  ok "PrivateKey: $priv"
  ok "PublicKey:  $pub"
  ok "ShortId:    $client_shortid"

  # Определить публичный IP этой EXIT-ноды
  local exit_ip
  exit_ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')

  # Собираем 3 JSON-блока
  local inbound_json outbound_json routing_json
  inbound_json=$(jq -n \
    --arg tag "VLESS_${cc_upper}" --argjson port "$entry_port" \
    --arg sni "$client_sni" --arg sid "$client_shortid" --arg priv "$priv" \
    '{
      tag: $tag, port: $port, listen: "0.0.0.0", protocol: "vless",
      settings: {clients: [], decryption: "none", flow: ""},
      sniffing: {enabled: true, destOverride: ["http","tls","quic"]},
      streamSettings: {
        network: "tcp", security: "reality",
        realitySettings: {
          dest: ($sni + ":443"), show: false, xver: 0,
          shortIds: [$sid], privateKey: $priv, serverNames: [$sni]
        }
      }
    }')

  outbound_json=$(jq -n \
    --arg tag "BRIDGE_${cc_upper}" --arg addr "$exit_ip" \
    --argjson port "$bridge_port" --arg uuid "$bridge_uuid" \
    --arg pub "$bridge_pub" --arg sid "$reality_shortid" --arg sni "$reality_sni" \
    '{
      tag: $tag, protocol: "vless",
      settings: {
        vnext: [{
          address: $addr, port: $port,
          users: [{id: $uuid, flow: "xtls-rprx-vision", encryption: "none"}]
        }]
      },
      streamSettings: {
        network: "tcp", security: "reality",
        realitySettings: {
          show: false, shortId: $sid, spiderX: "",
          publicKey: $pub, serverName: $sni, fingerprint: "chrome"
        }
      }
    }')

  routing_json=$(jq -n --arg ib "VLESS_${cc_upper}" --arg ob "BRIDGE_${cc_upper}" \
    '{type: "field", inboundTag: [$ib], outboundTag: $ob}')

  # Печать
  printf "\n%s\n" "$(c_grn '╔════════════════════════════════════════════════════════════╗')"
  printf "%s\n" "$(c_grn '║  Готово к копи-пасте в Remnawave Config Profile (Edit JSON) ║')"
  printf "%s\n\n" "$(c_grn '╚════════════════════════════════════════════════════════════╝')"

  printf "%s\n" "$(c_bold "▸ Добавьте в массив \"inbounds\":")"
  echo "$inbound_json" | jq .
  printf "\n%s\n" "$(c_bold "▸ Добавьте в массив \"outbounds\":")"
  echo "$outbound_json" | jq .
  printf "\n%s\n" "$(c_bold "▸ Добавьте в массив \"routing.rules\":")"
  echo "$routing_json" | jq .

  printf "\n%s\n" "$(c_bold '▸ Параметры нового Host в Remnawave UI:')"
  printf "  Remark:       %s Тест\n" "$cc_name"
  printf "  Inbound:      VLESS_%s\n" "$cc_upper"
  printf "  Address:      %s\n" "$entry_ip"
  printf "  Port:         %s\n" "$entry_port"
  printf "  PublicKey:    %s\n" "$pub"
  printf "  ShortId:      %s\n" "$client_shortid"
  printf "  SNI:          %s\n" "$client_sni"
  printf "  Fingerprint:  chrome\n"
  printf "  Mux:          %s\n" "$(c_red 'OFF (обязательно!)')"

  # Сохранить в файл
  local out_file="${GENERATED_DIR}/${cc}.json"
  jq -n \
    --argjson inbound "$inbound_json" \
    --argjson outbound "$outbound_json" \
    --argjson routing "$routing_json" \
    --arg country "$cc" --arg country_name "$cc_name" \
    --arg entry_ip "$entry_ip" --argjson entry_port "$entry_port" \
    --arg client_sni "$client_sni" --arg priv "$priv" --arg pub "$pub" \
    --arg client_shortid "$client_shortid" --arg bridge_name "$bridge_name" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      country: $country, country_name: $country_name, created_at: $ts,
      bridge_name: $bridge_name,
      entry_ip: $entry_ip, entry_port: $entry_port, client_sni: $client_sni,
      client_priv: $priv, client_pub: $pub, client_shortid: $client_shortid,
      blocks: {inbound: $inbound, outbound: $outbound, routing: $routing}
    }' > "$out_file"
  ok "Сохранено: $out_file"

  # Записать в state
  state_append '.exit.client_configs' "$(jq -c '{country, country_name, created_at, bridge_name, entry_ip, entry_port, client_sni, client_priv, client_pub, client_shortid}' "$out_file")"

  pause
}

# [2] Показать JSON-блоки для уже созданных стран
exit_show_countries() {
  header "Сохранённые конфиги стран"
  local count; count=$(state_count '.exit.client_configs')
  if [ "$count" -eq 0 ]; then
    info "Пока нет ни одной страны. Используйте пункт [1] чтобы добавить."
    pause; return
  fi
  local i=0
  local items=()
  while IFS= read -r cc; do
    local cn
    cn=$(jq -r --arg c "$cc" '.exit.client_configs[] | select(.country == $c) | .country_name' "$STATE_FILE")
    items+=("$cn ($cc)")
    i=$((i+1))
  done < <(jq -r '.exit.client_configs[].country' "$STATE_FILE")
  menu_select "Выберите страну для показа JSON-блоков:" "${items[@]}"
  local cc
  cc=$(jq -r ".exit.client_configs[$MENU_REPLY].country" "$STATE_FILE")
  local f="${GENERATED_DIR}/${cc}.json"
  if [ -f "$f" ]; then
    jq . "$f"
  else
    err "Файл $f не найден"
  fi
  pause
}

# [3] Экспорт credentials
exit_export_creds() {
  header "Экспорт credentials для другой EXIT-ноды"
  local b64
  b64=$(encode_creds)
  printf "\n%s\n\n" "$(c_bold 'Запустите ОДНУ команду на новой EXIT-ноде:')"
  printf "%s\n\n" "$(c_grn "curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | BRIDGE_CREDS='$b64' bash")"
  warn "Хранить эту строку как секрет — содержит приватные ключи моста!"
  pause
}

# [4] Подключить вторую ENTRY-ноду
exit_add_entry_node() {
  header "Подключение новой ENTRY-ноды"
  cat <<EOF

  Доступны два варианта:

  $(c_bold '[1] Общий мост') — новая ENTRY использует ТОТ ЖЕ UUID и порт что и существующие entries.
                    Просто, но при компрометации UUID — затронуты все ENTRY.

  $(c_bold '[2] Изолированный мост') — для новой ENTRY поднимется ОТДЕЛЬНЫЙ контейнер bridge-xray
                          на новом порту, со своими UUID и Reality-ключами.
                          Изоляция между проектами, отдельные секреты.

EOF
  local choice
  read -r -p "$(c_bold 'Выбор') [1/2]: " choice
  case "$choice" in
    1) info "Используйте параметры существующего моста при настройке ENTRY-ноды."
       printf "\n  Параметры:\n"
       jq -r '.exit.bridges[0] | "  UUID:       \(.uuid)\n  PublicKey:  \(.reality_pub)\n  ShortId:    \(.reality_shortid)\n  SNI:        \(.reality_sni)\n  Port:       \(.port)"' "$STATE_FILE"
       pause ;;
    2) exit_add_isolated_bridge ;;
    *) err "Неверный выбор"; pause ;;
  esac
}

exit_add_isolated_bridge() {
  step "Создание изолированного моста"
  local bname
  prompt "Имя нового моста (латиница, например 'proj2')"
  bname="${REPLY:-bridge2}"
  prompt "Порт TCP (default 7444)" "7444"
  local port="$REPLY"

  local transports=("Reality+TCP+Vision (рекомендую)" "Reality+xhttp (лучше для UDP-DNS)" "WireGuard (только plain WG)")
  menu_select "Выберите транспорт:" "${transports[@]}"
  local transport
  case "$MENU_REPLY" in
    0) transport=reality ;;
    1) transport=xhttp ;;
    2) transport=wg ;;
  esac

  local uuid kp priv pub sid
  uuid=$(gen_uuid)
  kp=$(gen_x25519) || { pause; return; }
  priv=$(echo "$kp" | sed -n '1p')
  pub=$(echo "$kp"  | sed -n '2p')
  sid=$(gen_shortid_8)

  case "$transport" in
    reality)
      deploy_bridge_reality "$bname" "$port" "$uuid" "$priv" "$sid" "max.ru" "max.ru:443" || { pause; return; }
      ;;
    xhttp)
      deploy_bridge_xhttp "$bname" "$port" "$uuid" "$priv" "$sid" "max.ru" "max.ru:443" || { pause; return; }
      ;;
    wg)
      local wg_out
      wg_out=$(deploy_bridge_wg "$bname" 51820 | tail -1)
      ok "WG-мост развёрнут — см. вывод выше"
      ;;
  esac

  state_append '.exit.bridges' "$(jq -n \
    --arg name "$bname" --argjson port "$port" --arg transport "$transport" \
    --arg uuid "$uuid" --arg priv "$priv" --arg pub "$pub" \
    --arg sid "$sid" --arg sni "max.ru" --arg dest "max.ru:443" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cn "bridge-xray-$bname" \
    '{name:$name, port:$port, transport:$transport, uuid:$uuid, reality_priv:$priv, reality_pub:$pub, reality_shortid:$sid, reality_sni:$sni, reality_dest:$dest, deployed_at:$ts, container_name:$cn}')"

  printf "\n%s\n" "$(c_bold 'Параметры нового моста (передайте на ENTRY-ноду):')"
  printf "  UUID:       %s\n" "$uuid"
  printf "  PublicKey:  %s\n" "$pub"
  printf "  ShortId:    %s\n" "$sid"
  printf "  Port:       %s\n" "$port"
  printf "  Transport:  %s\n" "$transport"
  pause
}

# [5] Тест моста с локали
exit_test_bridge() {
  header "Тест локального моста"
  local count; count=$(state_count '.exit.bridges')
  if [ "$count" -eq 0 ]; then info "Нет мостов"; pause; return; fi
  local bname port sni
  if [ "$count" -eq 1 ]; then
    bname=$(state_get '.exit.bridges[0].name')
    port=$(state_get '.exit.bridges[0].port')
    sni=$(state_get '.exit.bridges[0].reality_sni')
  else
    local names=()
    while IFS= read -r n; do names+=("$n"); done < <(jq -r '.exit.bridges[].name' "$STATE_FILE")
    menu_select "Какой мост тестировать?" "${names[@]}"
    bname="${names[$MENU_REPLY]}"
    port=$(jq -r --arg n "$bname" '.exit.bridges[] | select(.name == $n) | .port' "$STATE_FILE")
    sni=$(jq -r  --arg n "$bname" '.exit.bridges[] | select(.name == $n) | .reality_sni' "$STATE_FILE")
  fi
  step "Проверяю localhost:$port"
  if timeout 4 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then
    ok "Порт $port слушается"
  else
    err "Порт $port не отвечает"; pause; return
  fi
  step "TLS-handshake к ${sni}"
  if timeout 5 openssl s_client -connect "127.0.0.1:$port" -servername "$sni" -tls1_3 < /dev/null 2>&1 | grep -q "CN *= *${sni}"; then
    ok "Reality OK (CN=$sni)"
  else
    warn "Reality handshake не подтвердился — проверьте логи контейнера"
  fi
  step "Live-статистика контейнера (5 сек)"
  timeout 5 docker stats --no-stream "bridge-xray-${bname}" 2>/dev/null || warn "docker stats недоступен"
  pause
}

# [6] Live-логи
exit_live_logs() {
  header "Live-логи bridge-xray (Ctrl+C для выхода)"
  local count; count=$(state_count '.exit.bridges')
  if [ "$count" -eq 0 ]; then info "Нет мостов"; pause; return; fi
  local bname
  if [ "$count" -eq 1 ]; then
    bname=$(state_get '.exit.bridges[0].name')
  else
    local names=()
    while IFS= read -r n; do names+=("$n"); done < <(jq -r '.exit.bridges[].name' "$STATE_FILE")
    menu_select "Логи какого моста?" "${names[@]}"
    bname="${names[$MENU_REPLY]}"
  fi
  docker logs -f --tail 50 "bridge-xray-${bname}" || true
  pause
}

# [7] Перезапустить
exit_restart_bridge() {
  header "Перезапуск bridge-xray"
  local count; count=$(state_count '.exit.bridges')
  if [ "$count" -eq 0 ]; then info "Нет мостов"; pause; return; fi
  while IFS= read -r bname; do
    step "Перезапускаю bridge-xray-${bname}"
    docker restart "bridge-xray-${bname}" >/dev/null 2>&1 && ok "Готово" || err "Ошибка"
  done < <(jq -r '.exit.bridges[].name' "$STATE_FILE")
  pause
}

# [8] Удалить
exit_uninstall_menu() {
  header "Удаление моста"
  local count; count=$(state_count '.exit.bridges')
  if [ "$count" -eq 0 ]; then info "Нет мостов"; pause; return; fi
  local names=()
  while IFS= read -r n; do names+=("$n"); done < <(jq -r '.exit.bridges[].name' "$STATE_FILE")
  names+=("← Назад")
  menu_select "Какой мост удалить?" "${names[@]}"
  if [ "$MENU_REPLY" -eq "$((${#names[@]} - 1))" ]; then return; fi
  local target="${names[$MENU_REPLY]}"
  if confirm "Точно удалить мост '$target' и его контейнер?" "n"; then
    uninstall_bridge "$target"
    # Удалить из state
    local tmp; tmp=$(mktemp)
    jq --arg n "$target" '.exit.bridges |= map(select(.name != $n))' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    ok "Удалено"
  fi
  pause
}
