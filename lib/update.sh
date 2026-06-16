#!/usr/bin/env bash
# lib/update.sh — git pull + restart CLI.

update_from_git() {
  local home="${BRIDGE_CLI_HOME:-/opt/bridge-cli}"
  if [ ! -d "$home/.git" ]; then
    err "Установка не из git: $home/.git отсутствует. Переустановите через install.sh"
    return 1
  fi
  step "Обновление bridge-cli из GitHub"
  local before
  before=$(git -C "$home" rev-parse --short HEAD 2>/dev/null || echo "?")
  if git -C "$home" pull --rebase --autostash 2>&1; then
    local after
    after=$(git -C "$home" rev-parse --short HEAD 2>/dev/null || echo "?")
    if [ "$before" = "$after" ]; then
      ok "Уже актуальная версия ($after)"
    else
      ok "Обновлено: $before → $after"
      info "Перезапускаю bridge-cli..."
      exec "$home/bin/bridge-cli" "$@"
    fi
  else
    err "git pull завершился с ошибкой"
    return 1
  fi
}
