#!/usr/bin/env bash
# lib/ui.sh — рендеринг меню, цвета, prompts.

# Цвета (с fallback если нет TTY)
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3)
  C_BLU=$(tput setaf 4); C_MAG=$(tput setaf 5); C_CYN=$(tput setaf 6)
  C_BOLD=$(tput bold); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""; C_CYN=""; C_BOLD=""; C_RST=""
fi

c_red()  { printf "%s%s%s" "$C_RED"  "$*" "$C_RST"; }
c_grn()  { printf "%s%s%s" "$C_GRN"  "$*" "$C_RST"; }
c_yel()  { printf "%s%s%s" "$C_YEL"  "$*" "$C_RST"; }
c_blu()  { printf "%s%s%s" "$C_BLU"  "$*" "$C_RST"; }
c_cyn()  { printf "%s%s%s" "$C_CYN"  "$*" "$C_RST"; }
c_bold() { printf "%s%s%s" "$C_BOLD" "$*" "$C_RST"; }

ok()    { printf "  %s %s\n" "$(c_grn '✓')" "$*"; }
warn()  { printf "  %s %s\n" "$(c_yel '⚠')" "$*"; }
err()   { printf "  %s %s\n" "$(c_red '✗')" "$*" >&2; }
info()  { printf "  %s %s\n" "$(c_blu 'ℹ')" "$*"; }
step()  { printf "\n%s %s\n" "$(c_blu '▸')" "$(c_bold "$*")"; }

# Шапка
header() {
  local title="$1"; local subtitle="${2:-}"
  local width=64
  printf "\n%s\n" "$(c_cyn "╔$(printf '═%.0s' $(seq 1 $width))╗")"
  printf "%s %-${width}s %s\n" "$(c_cyn '║')" "$(c_bold "$title")" "$(c_cyn '║')"
  if [ -n "$subtitle" ]; then
    printf "%s %-${width}s %s\n" "$(c_cyn '║')" "$subtitle" "$(c_cyn '║')"
  fi
  printf "%s\n" "$(c_cyn "╚$(printf '═%.0s' $(seq 1 $width))╝")"
}

divider() {
  printf "%s\n" "$(c_cyn "──────────────────────────────────────────────────────────────")"
}

# prompt "Введите IP" "default_value" → читает в $REPLY
prompt() {
  local msg="$1"; local default="${2:-}"
  local p
  if [ -n "$default" ]; then
    p="$(c_bold "$msg") [$default]: "
  else
    p="$(c_bold "$msg"): "
  fi
  read -r -p "$p" REPLY
  if [ -z "$REPLY" ] && [ -n "$default" ]; then
    REPLY="$default"
  fi
  printf "%s" "$REPLY"
}

# confirm "Продолжить?" "y" → возвращает 0/1
confirm() {
  local msg="$1"; local default="${2:-y}"
  local hint
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  local ans
  read -r -p "$(c_bold "$msg") $hint: " ans
  ans="${ans:-$default}"
  case "$ans" in
    y|Y|yes|YES|да|Д|д) return 0 ;;
    *) return 1 ;;
  esac
}

# pause "Нажмите Enter для продолжения" — блокирует
pause() {
  local msg="${1:-Нажмите Enter для продолжения}"
  read -r -p "$(c_yel "$msg")..." _
}

# menu_select "Заголовок" "опция1" "опция2" ... → возвращает 0-based index в $MENU_REPLY
menu_select() {
  local title="$1"; shift
  local opts=("$@")
  local i=1
  printf "\n%s\n" "$(c_bold "$title")"
  for opt in "${opts[@]}"; do
    printf "  [%s]  %s\n" "$(c_cyn "$i")" "$opt"
    i=$((i+1))
  done
  while true; do
    read -r -p "$(c_bold 'Выбор'): " MENU_REPLY
    if [[ "$MENU_REPLY" =~ ^[0-9]+$ ]] && [ "$MENU_REPLY" -ge 1 ] && [ "$MENU_REPLY" -le "${#opts[@]}" ]; then
      MENU_REPLY=$((MENU_REPLY-1))
      return 0
    fi
    err "Неверный выбор, введите число от 1 до ${#opts[@]}"
  done
}

# Проверка root
require_root() {
  if [ "$EUID" -ne 0 ]; then
    err "Требуются права root. Запустите через sudo."
    exit 1
  fi
}

# Trap Ctrl+C — возврат в меню вместо выхода
trap_sigint() {
  trap 'printf "\n%s\n" "$(c_yel "↩ Прервано пользователем, возврат в меню...")"; return 1 2>/dev/null || true' INT
}
