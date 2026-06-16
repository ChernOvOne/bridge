#!/usr/bin/env bash
# lib/crypto.sh — генерация Reality keypair, UUID, shortId, credentials encode/decode.

XRAY_IMAGE_DEFAULT="ghcr.io/xtls/xray-core:latest"

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    # Fallback: openssl
    python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
      printf '%s-%s-%s-%s-%s\n' \
        "$(openssl rand -hex 4)" "$(openssl rand -hex 2)" "$(openssl rand -hex 2)" \
        "$(openssl rand -hex 2)" "$(openssl rand -hex 6)"
  fi
}

# Возвращает private/public через xray x25519. Стдаут: priv\npub
gen_x25519() {
  local img="${XRAY_IMAGE:-$XRAY_IMAGE_DEFAULT}"
  local out
  out=$(docker run --rm "$img" x25519 2>/dev/null) || {
    err "Не удалось запустить docker run xray x25519 — проверьте Docker"
    return 1
  }
  local priv pub
  priv=$(echo "$out" | awk -F': ' '/Private/ {print $2}' | tr -d '[:space:]')
  pub=$(echo  "$out" | awk -F': ' '/Public/  {print $2}' | tr -d '[:space:]')
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    err "Не удалось распарсить x25519 keypair"
    return 1
  fi
  printf "%s\n%s\n" "$priv" "$pub"
}

# Производный public из private (для существующего priv-key) — увы, нужен xray-core с этой фичей.
# Альтернативы нет, используем xray.
derive_x25519_pub() {
  local priv="$1"
  local img="${XRAY_IMAGE:-$XRAY_IMAGE_DEFAULT}"
  docker run --rm "$img" x25519 -i "$priv" 2>/dev/null | \
    awk -F': ' '/Public/ {print $2}' | tr -d '[:space:]'
}

gen_shortid_16() {
  openssl rand -hex 8 2>/dev/null || head -c 16 /dev/urandom | xxd -p -c 16 | head -c 16
}

gen_shortid_8() {
  openssl rand -hex 4 2>/dev/null || head -c 8 /dev/urandom | xxd -p -c 8 | head -c 8
}

# encode_creds — берёт state.exit.bridges[0] + iperf3 и упаковывает в base64
encode_creds() {
  local b64
  b64=$(jq -c '{
    bridges: .exit.bridges,
    iperf3:  .exit.iperf3
  }' "$STATE_FILE" | base64 -w0 2>/dev/null || jq -c '{
    bridges: .exit.bridges,
    iperf3:  .exit.iperf3
  }' "$STATE_FILE" | base64 | tr -d '\n')
  printf "%s" "$b64"
}

# decode_creds — из base64 в JSON
decode_creds() {
  local b64="$1"
  echo "$b64" | base64 -d 2>/dev/null
}

# Авто-подбор SNI по стране для клиентского inbound
sni_for_country() {
  local cc; cc=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  case "$cc" in
    us|usa)        echo "amazon.com" ;;
    uk|gb)         echo "bbc.co.uk" ;;
    fr)            echo "wildberries.ru" ;;
    de)            echo "vk.com" ;;
    nl)            echo "ozon.ru" ;;
    pl)            echo "yandex.ru" ;;
    kz)            echo "mail.ru" ;;
    ru)            echo "rambler.ru" ;;
    jp)            echo "rakuten.co.jp" ;;
    sg)            echo "shopee.sg" ;;
    fi)            echo "yle.fi" ;;
    se)            echo "svt.se" ;;
    *)             echo "cloudflare.com" ;;
  esac
}

# Человеческое название страны
country_name() {
  local cc; cc=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  case "$cc" in
    us|usa) echo "США" ;;  uk|gb) echo "Великобритания" ;;
    fr) echo "Франция" ;;  de) echo "Германия" ;;
    nl) echo "Нидерланды" ;; pl) echo "Польша" ;;
    kz) echo "Казахстан" ;;  ru) echo "Россия" ;;
    jp) echo "Япония" ;;    sg) echo "Сингапур" ;;
    fi) echo "Финляндия" ;;  se) echo "Швеция" ;;
    it) echo "Италия" ;;    es) echo "Испания" ;;
    cz) echo "Чехия" ;;     no) echo "Норвегия" ;;
    *) echo "$(echo "$cc" | tr '[:lower:]' '[:upper:]')" ;;
  esac
}
