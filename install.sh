#!/usr/bin/env bash
# install.sh — one-line installer для bridge-cli.
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | BRIDGE_CREDS='base64' bash
set -euo pipefail

# При запуске через `curl | bash` stdin занят пайпом → интерактивный read получит EOF.
# Переоткрываем stdin как TTY, если она доступна.
if [ ! -t 0 ] && [ -e /dev/tty ]; then
  exec < /dev/tty
fi

INSTALL_DIR="/opt/bridge-cli"
REPO_URL="https://github.com/ChernOvOne/bridge.git"
BRANCH="main"

if [ "$EUID" -ne 0 ]; then
  echo "✗ Запустите от root (sudo bash ...)" >&2
  exit 1
fi

c_blu() { printf "\033[1;34m%s\033[0m" "$1"; }
c_grn() { printf "\033[1;32m%s\033[0m" "$1"; }
c_red() { printf "\033[1;31m%s\033[0m" "$1"; }
c_yel() { printf "\033[1;33m%s\033[0m" "$1"; }
c_bold(){ printf "\033[1m%s\033[0m" "$1"; }

step() { printf "\n%s %s\n" "$(c_blu '▸')" "$(c_bold "$1")"; }
ok()   { printf "  %s %s\n" "$(c_grn '✓')" "$1"; }
warn() { printf "  %s %s\n" "$(c_yel '⚠')" "$1"; }
err()  { printf "  %s %s\n" "$(c_red '✗')" "$1" >&2; }

detect_pkg_mgr() {
  if   command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf     >/dev/null 2>&1; then echo dnf
  elif command -v yum     >/dev/null 2>&1; then echo yum
  elif command -v apk     >/dev/null 2>&1; then echo apk
  else echo unknown
  fi
}

PKG=$(detect_pkg_mgr)
if [ "$PKG" = "unknown" ]; then
  err "Неподдерживаемый пакетный менеджер (нужен apt/dnf/yum/apk)"
  exit 1
fi

cat <<EOF
╔══════════════════════════════════════════════════════════╗
║          bridge-cli — installer                          ║
╚══════════════════════════════════════════════════════════╝
EOF

step "Обновление системы"
case "$PKG" in
  apt)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get -y -qq upgrade
    ;;
  dnf) dnf -y -q upgrade ;;
  yum) yum -y -q update ;;
  apk) apk update -q && apk upgrade -q ;;
esac
ok "Система обновлена"

step "Установка зависимостей (jq, dialog, openssl, curl, iperf3, git, ca-certificates)"
case "$PKG" in
  apt) apt-get install -y -qq jq dialog openssl curl ca-certificates iperf3 git ;;
  dnf) dnf install -y -q jq dialog openssl curl ca-certificates iperf3 git ;;
  yum) yum install -y -q jq dialog openssl curl ca-certificates iperf3 git ;;
  apk) apk add --no-cache jq dialog openssl curl ca-certificates iperf3 git bash ;;
esac
ok "Зависимости установлены"

step "Установка Docker"
if command -v docker >/dev/null 2>&1; then
  ok "Docker уже стоит ($(docker --version))"
else
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true
  ok "Docker установлен"
fi

step "Клонирование bridge-cli в $INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" pull --rebase --autostash 2>&1 | tail -3
  ok "Обновлено (git pull)"
else
  rm -rf "$INSTALL_DIR"
  git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR" 2>&1 | tail -3
  ok "Склонировано"
fi

step "Симлинк /usr/local/bin/br → $INSTALL_DIR/bin/bridge-cli"
chmod +x "$INSTALL_DIR/bin/bridge-cli"
ln -sf "$INSTALL_DIR/bin/bridge-cli" /usr/local/bin/br
ok "Команда 'br' доступна глобально"

# Если есть BRIDGE_CREDS — сохранить для init wizard
if [ -n "${BRIDGE_CREDS:-}" ]; then
  step "Применяю переданные credentials"
  mkdir -p "$INSTALL_DIR/etc"
  if echo "$BRIDGE_CREDS" | base64 -d 2>/dev/null > "$INSTALL_DIR/etc/preinit-creds.json"; then
    if jq . "$INSTALL_DIR/etc/preinit-creds.json" >/dev/null 2>&1; then
      ok "Credentials валидны и сохранены — будут импортированы при br init"
    else
      err "BRIDGE_CREDS не является валидным JSON после base64-decode"
      rm -f "$INSTALL_DIR/etc/preinit-creds.json"
    fi
  else
    err "BRIDGE_CREDS не декодируется из base64"
  fi
fi

step "Запуск 'br init' для настройки роли"
echo
if [ -t 0 ] || [ -e /dev/tty ]; then
  exec /usr/local/bin/br init
else
  warn "stdin недоступен (cron/headless) — запусти 'br init' вручную в интерактивной сессии"
  exit 0
fi
