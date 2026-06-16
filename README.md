# bridge — утилиты для расширения VLESS+Reality bridge VPN-сервиса

Два самодостаточных bash-скрипта для быстрого добавления **foreign exit-нод** (как DE/FR/NL/PL/KZ) в существующую bridge-архитектуру через **entry-ноду** (как Aeza) с панелью Remnawave.

## Архитектура (для контекста)

```
   Клиент (Россия, Happp/v2rayNG)
              │
              │  VLESS+Reality+TCP (без vision)
              ▼
   Entry-нода (Aeza, RU, ptr.network)
   - remnanode (Remnawave Node)
   - rw-core слушает VLESS_XX inbound на отдельных портах
   - routing: VLESS_XX → BRIDGE_XX outbound
              │
              │  VLESS+Reality+TCP+Vision к :7443
              ▼
   Foreign exit-нода (любая страна)
   - bridge-xray (standalone Docker)
   - слушает :7443 VLESS+Reality+Vision
   - outbound: freedom → реальный интернет
```

**Ключевая идея:** entry-нода маскирует трафик клиента под Reality к bridge-xray. Bridge-xray НЕ подключён к Remnawave-панели — это просто standalone-listener с общим UUID и общим Reality-keypair. Каждая страна — отдельный inbound на entry-ноде с уникальным client-side Reality-keypair.

---

## Скрипт 1: `bootstrap-exit.sh` — развернуть новую exit-ноду

**Запуск на foreign-ноде (US/UK/JP/...) от root:**

```bash
BRIDGE_UUID='45530698-67ee-4ace-91ae-f495f34a4e88' \
BRIDGE_REALITY_PRIV='QIh-HLgOUS6jX5Vdn-slSWBoLKFcgocmuXfDZ85n7EI' \
BRIDGE_REALITY_SHORTID='61dfff54' \
ENTRY_IP='45.152.198.131' \
ENTRY_PORT='2087' \
bash <(curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/bootstrap-exit.sh) us
```

### Обязательные ENV-переменные

| Переменная | Описание | Где взять |
|---|---|---|
| `BRIDGE_UUID` | Общий UUID, который entry-нода использует для подключения к bridge-xray | Из конфига существующих exit-нод (общий для всех) |
| `BRIDGE_REALITY_PRIV` | Reality privateKey для bridge-inbound | Сгенерён единожды при создании первого bridge |
| `BRIDGE_REALITY_SHORTID` | Reality shortId для bridge (общий) | Тот же, что в BRIDGE_DE/FR/NL/... outbound (например `61dfff54`) |
| `ENTRY_IP` | IP вашей entry-ноды (Aeza), которая будет подключаться к этому bridge | Например `45.152.198.131` |
| `ENTRY_PORT` | Свободный TCP-порт на entry-ноде для VLESS_XX inbound | Подбери из safe-list (см. ниже), не должен быть занят |

### Опциональные ENV-переменные

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `BRIDGE_REALITY_SNI` | `max.ru` | SNI Reality для bridge (под что маскируется) |
| `BRIDGE_REALITY_DEST` | `max.ru:443` | dest Reality для bridge |
| `BRIDGE_PORT` | `7443` | Порт bridge-xray (можно поменять, не забыть в EntryNode-конфиге) |
| `CLIENT_SNI` | автомат по стране | SNI клиентского inbound (US=amazon.com, FR=wildberries.ru, ...) |
| `XRAY_IMAGE` | `ghcr.io/xtls/xray-core:latest` | Docker image для xray |
| `INSTALL_DIR` | `/opt/bridge-xray` | Куда положить config.json |

### Что скрипт делает

1. Ставит Docker (если ещё не стоит) — apt/dnf/yum/apk
2. Открывает `7443/tcp` в UFW / firewalld / iptables
3. Создаёт `/opt/bridge-xray/{config.json,docker-compose.yml}` с общими bridge-ключами
4. Запускает Docker-контейнер `bridge-xray` (network=host, restart=unless-stopped)
5. Smoke-test (`/dev/tcp/127.0.0.1/7443`)
6. Генерирует **уникальный** client-side Reality keypair через `docker run xray x25519`
7. Печатает готовые JSON-блоки для копи-пасты в Remnawave Config Profile + параметры для нового Host в UI

### Безопасные порты для `ENTRY_PORT`

Не блокируются российскими провайдерами:
- `443`, `2087`, `2083`, `8443`, `8447`, `8448`, `8449`, `2096`

Часто фильтруются MTS-NN, не использовать:
- `2053` (cloudflare-ish), всё что > 50000

Проверь свободные на entry-ноде:
```bash
ss -tlnp | sort -k4 -n -t':'
```

### После запуска скрипта

Скопируй три JSON-блока в **Remnawave panel → Config Profiles → Edit Raw JSON**:
- Один в `inbounds` массив
- Один в `outbounds` массив  
- Один в `routing.rules` массив

Замени плейсхолдер `<ВСТАВЬ публичный ключ от BRIDGE_REALITY_PRIV>` в outbound — это публичный ключ соответствующий твоему `BRIDGE_REALITY_PRIV` (получить: `echo PRIV | docker run --rm -i ghcr.io/xtls/xray-core:latest x25519 -i` — да, для уже существующего priv-key используй существующий pub-key из конфига какого-нибудь BRIDGE_XX outbound).

Затем создай **Host** в UI по параметрам из вывода скрипта.

Save → подписка обновится → клиенты подхватят.

---

## Скрипт 2: `probe-from-entry.sh` — проверка кандидатов на exit-ноду

**Запуск на entry-ноде (Aeza, RU) от root:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/probe-from-entry.sh) \
    77.110.116.16 45.12.133.36 206.206.103.163
```

### Опциональные ENV

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `BRIDGE_PORT` | `7443` | Какой порт проверять на foreign-нодах |
| `BRIDGE_REALITY_SNI` | `max.ru` | Ожидаемый SNI Reality (для валидации что это наш bridge) |
| `PING_COUNT` | `10` | Сколько ping-пакетов |
| `IPERF` | `0` | `=1` для throughput-теста (нужен iperf3 на foreign-ноде) |

### Что проверяет

Для каждого IP:
- **ping** — packet loss + average RTT
- **TCP-connect** к `7443` — доступен ли bridge-порт
- **TLS handshake** через openssl — отвечает ли с `CN=max.ru` (то есть наш bridge-xray)
- **MTU discovery** через tracepath
- **Verdict**: `✅ excellent` / `⚠ packet loss` / `⚠ wrong CN` / `❌ unreachable`

### Использование при планировании

1. Получил новую foreign-ноду — **сначала** проверь:
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/probe-from-entry.sh) <new_ip>
   ```
2. Если `❌ unreachable` → ставить bridge-xray бесполезно (TSPU блокирует или firewall). Поменяй ноду.
3. Если `✅ excellent` → запусти `bootstrap-exit.sh` на новой ноде.
4. **После** развёртывания снова запусти `probe-from-entry.sh` чтобы убедиться что Reality живёт и MTU нормальный.

---

## Подробный сценарий: добавить новую страну с нуля

Допустим, купил **JP-ноду** `45.67.89.10` (Tokyo), нужно добавить «Япония» в подписку.

### Шаг 1 — Probe из Aeza

```bash
# На Aeza:
bash <(curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/probe-from-entry.sh) 45.67.89.10
```

Ожидаем `❌ unreachable` (потому что bridge-xray ещё не развёрнут). Главное — `ping OK` (значит TSPU нас не режет).

### Шаг 2 — Bootstrap JP-ноды

```bash
# На JP-ноде (ssh root@45.67.89.10):
BRIDGE_UUID='45530698-67ee-4ace-91ae-f495f34a4e88' \
BRIDGE_REALITY_PRIV='<твой_приватный_ключ_моста>' \
BRIDGE_REALITY_SHORTID='61dfff54' \
ENTRY_IP='45.152.198.131' \
ENTRY_PORT='8449' \
bash <(curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/bootstrap-exit.sh) jp
```

Скрипт ставит Docker, поднимает bridge-xray, генерит уникальный client-keypair и печатает 3 JSON-блока + параметры Host.

### Шаг 3 — Подтверждение через probe

```bash
# Обратно на Aeza:
bash <(curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/probe-from-entry.sh) 45.67.89.10
```

Должно стать `✅ excellent`.

### Шаг 4 — Remnawave Panel

1. Открой **Config Profiles → Edit Raw JSON**:
   - Вставь `VLESS_JP` в `inbounds[]`
   - Вставь `BRIDGE_JP` в `outbounds[]` (не забудь подставить публичный ключ моста!)
   - Вставь routing-rule в `routing.rules[]`
   - Save

2. Открой **Hosts → New Host**:
   - Скопируй параметры из вывода скрипта (Address, Port, PublicKey, ShortId, SNI, FP, Mux=OFF)
   - Привяжи к inbound `VLESS_JP`
   - Save

### Шаг 5 — Refresh подписок

Клиенты подхватят новый Host автоматически при следующем обновлении подписки (или принудительно через pull-to-refresh в Happp/v2rayNG).

---

## Безопасность

- **Никогда** не помещай `BRIDGE_UUID`, `BRIDGE_REALITY_PRIV`, `BRIDGE_REALITY_SHORTID` в git
- Передавай их только через ENV-переменные при запуске скрипта
- Если ключи скомпрометированы — перегенерируй их и пере-разверни bridge-xray на ВСЕХ exit-нодах одновременно (а в Remnawave обнови outbound-блоки)
- bridge-xray слушает на `0.0.0.0:7443` — можно ограничить через firewall только IP entry-ноды, если параноишь

---

## Troubleshooting

### bootstrap-exit.sh падает на `docker run xray x25519`
Скрипт пытается сгенерить keypair через xray-image, но если pull-долго или fail — установи xray локально и сгенерь руками:
```bash
docker run --rm ghcr.io/xtls/xray-core:latest x25519
```

### probe показывает ❌ unreachable но `ping OK`
Это значит TCP/7443 закрыт. Проверь:
```bash
# На foreign-ноде:
ufw status | grep 7443
docker ps | grep bridge-xray
docker logs bridge-xray --tail 50
```

### probe показывает ⚠ wrong CN
Открыт порт 7443, но отвечает не наш bridge — другой сервис на этом порту. Проверь `docker ps` и убей лишнее.

### Клиент не видит сайтов после добавления Host
- Проверь что у Host **Mux: OFF** (Mux несовместим с Vision)
- Проверь подписку: `curl https://<твой_sub_url>` — есть ли новый хост в base64-списке
- Принудительно обнови подписку в клиенте (pull-to-refresh)

---

## Связанные проекты

- [Remnawave](https://github.com/remnawave/backend) — панель управления нодами
- [Xray-core](https://github.com/XTLS/Xray-core) — движок proxy

## Лицензия

MIT.
