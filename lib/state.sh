#!/usr/bin/env bash
# lib/state.sh — CRUD над etc/state.json через jq.

STATE_DIR="${BRIDGE_CLI_HOME:-/opt/bridge-cli}/etc"
STATE_FILE="${STATE_DIR}/state.json"
PREINIT_CREDS="${STATE_DIR}/preinit-creds.json"

# Создать пустой state.json если нет
state_init_empty() {
  mkdir -p "$STATE_DIR"
  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" <<'EOF'
{
  "version": "1.0.0",
  "installed_at": null,
  "role": null,
  "exit": {
    "bridges": [],
    "iperf3": {"enabled": false, "port": 5201, "allowed_ips": []},
    "client_configs": []
  },
  "entry": {
    "exit_nodes": []
  }
}
EOF
  fi
}

state_exists() {
  [ -f "$STATE_FILE" ] && jq -e '.role' "$STATE_FILE" >/dev/null 2>&1
}

state_role() {
  if state_exists; then
    jq -r '.role // empty' "$STATE_FILE"
  fi
}

# state_get '.exit.bridges[0].uuid' → значение
state_get() {
  jq -r "$1" "$STATE_FILE" 2>/dev/null || echo ""
}

state_get_raw() {
  jq "$1" "$STATE_FILE" 2>/dev/null
}

# state_set '.role = "exit"'
state_set() {
  local query="$1"
  local tmp
  tmp=$(mktemp)
  jq "$query" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# state_set_str '.role' 'exit' — безопасное обновление строкового значения
state_set_str() {
  local path="$1"; local value="$2"
  local tmp
  tmp=$(mktemp)
  jq --arg v "$value" "$path = \$v" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# state_append '.exit.bridges' '{"name":"main",...}'
state_append() {
  local path="$1"; local json="$2"
  local tmp
  tmp=$(mktemp)
  jq --argjson item "$json" "$path += [\$item]" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# state_delete_at '.entry.exit_nodes' 2  — удалить элемент массива по индексу
state_delete_at() {
  local path="$1"; local idx="$2"
  local tmp
  tmp=$(mktemp)
  jq "del($path[$idx])" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_count() {
  jq -r "$1 | length" "$STATE_FILE" 2>/dev/null || echo 0
}

# Запись installed_at и роли при init
state_complete_init() {
  local role="$1"
  state_set_str '.installed_at' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_set_str '.role' "$role"
}
