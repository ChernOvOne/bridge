# bridge-cli

Утилита `br` для управления **VLESS+Reality bridge-VPN-инфраструктурой**: разворачивает зарубежные exit-ноды одной командой, тестирует их с entry-стороны, генерирует готовые JSON-блоки для копи-пасты в Remnawave-панель.

## Установка

Одной командой на любой Linux-ноде (root, apt/dnf/yum/apk):

**Вариант 1 — git clone (рекомендуется, самый надёжный):**
```bash
rm -rf /tmp/bridge-src && git clone --depth 1 https://github.com/ChernOvOne/bridge.git /tmp/bridge-src && bash /tmp/bridge-src/install.sh
```

**Вариант 2 — curl | bash (если хостер не блокирует raw.githubusercontent.com):**
```bash
curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | bash
```

**Вариант 3 — двух-шаговый (если pipe зависает):**
```bash
curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh -o /tmp/inst.sh && bash /tmp/inst.sh
```

**Вариант 4 — через wget:**
```bash
wget -qO- https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | bash
```

> 💡 На многих хостингах (RuVDS, ptr.network, etc.) `raw.githubusercontent.com` блокируется — тогда варианты 2/3/4 не сработают, но **git clone всегда работает**. Поэтому он первый в списке.

Что произойдёт при любом варианте:

1. Обновляется система (`apt upgrade` / аналог)
2. Ставятся зависимости: `jq dialog openssl curl iperf3 git ca-certificates`
3. Ставится Docker (через `get.docker.com`) если ещё нет
4. Клонируется этот репо в `/opt/bridge-cli/`
5. Создаётся симлинк `/usr/local/bin/br`
6. Запускается `br init` — wizard выбора роли

После установки команда `br` доступна глобально.

### Установка дополнительной EXIT-ноды (с уже существующими credentials)

На первой EXIT-ноде (или ENTRY-ноде) в меню → **«Экспорт credentials»** — получишь готовую строку. Запусти её на новой EXIT-ноде:

**Рекомендуемый способ — git clone + creds:**
```bash
rm -rf /tmp/bridge-src && git clone --depth 1 https://github.com/ChernOvOne/bridge.git /tmp/bridge-src
BRIDGE_CREDS='<base64-blob>' bash /tmp/bridge-src/install.sh
```

Или через curl (если хостер пропускает):
```bash
curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | BRIDGE_CREDS='<base64-blob>' bash
```

Скрипт распакует ключи, развернёт bridge-xray с теми же UUID/Reality-keys, добавит к общему мосту.

### Ещё проще — через `br` на ENTRY-ноде

Если у тебя уже есть ENTRY-нода с установленным `br`, добавь exit-ноду через меню:
```
br → [1] Управление exit-нодами → [1] Добавить
```

CLI попросит IP/код страны/порт, сам сгенерит client-keypair, **распечатает 4 варианта установочной команды** для копи-пасты на новой ноде и сохранит их в файл `/opt/bridge-cli/etc/generated/<cc>-install-cmd.sh` (можно скопировать через scp).

---

## Архитектура

```
   Клиент (Россия, Happp/v2rayNG)
              │
              │  VLESS+Reality+TCP (без vision на этом плече)
              ▼
   ENTRY-нода (Россия, Aeza/etc)
   - remnanode + rw-core (управляется Remnawave-панелью)
   - VLESS_XX inbound на отдельных портах
   - routing: VLESS_XX → BRIDGE_XX outbound
              │
              │  VLESS+Reality+TCP+Vision к :7443
              ▼
   EXIT-нода (любая страна)
   - standalone bridge-xray (Docker) на :7443
   - outbound: freedom → реальный интернет
   - опционально: iperf3-сервер для тестов скорости
```

**EXIT-ноды НЕ подключаются к Remnawave-панели** — это просто Reality-listener'ы с общим UUID моста. Каждая страна на ENTRY = отдельный inbound с уникальным client-side Reality-keypair.

---

## Использование

### `br` — главное меню

При первом запуске покажет init-wizard выбора роли (EXIT / ENTRY), при последующих — главное меню соответствующей роли.

### EXIT-режим (зарубежная нода)

```
[1]  Добавить новую страну в подписку     ← генерит уникальный client-keypair + 3 JSON-блока
[2]  Показать JSON-блоки сохранённых стран
[3]  Экспорт credentials                  ← одна curl-строка для развёртывания следующей EXIT
[4]  Подключить вторую ENTRY-ноду         ← общий или изолированный мост
[5]  Тест моста (TLS, порт, скорость)
[6]  Live-логи bridge-xray
[7]  Перезапустить bridge-xray
[8]  Удалить мост
[9]  Обновить bridge-cli из GitHub
[0]  Выход
```

### ENTRY-режим (российская/прокси-нода)

```
[1]  Управление exit-нодами               ← inventory: добавить/удалить
[2]  Тест ОДНОЙ exit-ноды                 ← ping, port, Reality, MTU
[3]  Тест ВСЕХ exit-нод
[4]  Тест скорости (iperf3)
[5]  История тестов (10 дней)
[6]  Самодиагностика (интерфейсы, маршруты, MTU)
[7]  Сгенерировать xray-блоки для Remnawave
[9]  Обновить bridge-cli из GitHub
[0]  Выход
```

### CLI-команды (для скриптов)

```bash
br                # интерактивное меню (по роли)
br init           # wizard первого запуска
br status         # короткий статус (для cron/health-checks)
br probe <ip>     # одиночный тест ноды
br update         # git pull + restart
br --help
```

---

## Сценарий: добавить новую страну с нуля

Допустим, купили **JP-ноду** `45.67.89.10`, нужно добавить «Япония» в подписку.

### Шаг 1 — На ENTRY-ноде (Aeza)

```bash
br
# [2] Тест ОДНОЙ exit-ноды → 45.67.89.10
```

Если **TCP/7443 unreachable** при нормальном ping — значит bridge-xray ещё не развёрнут. Главное чтобы ping работал (TSPU не блокирует маршрут).

### Шаг 2 — На JP-ноде

Рекомендуемый способ (git clone — обходит блокировки):
```bash
ssh root@45.67.89.10
rm -rf /tmp/bridge-src && git clone --depth 1 https://github.com/ChernOvOne/bridge.git /tmp/bridge-src
BRIDGE_CREDS='<creds>' bash /tmp/bridge-src/install.sh
```

Или через curl если хостер пропускает:
```bash
ssh root@45.67.89.10
curl -fsSL https://raw.githubusercontent.com/ChernOvOne/bridge/main/install.sh | BRIDGE_CREDS='<creds>' bash
```

(Где `<creds>` — то что выдал «Экспорт credentials» в меню.)

### Шаг 3 — Создать конфиг страны (на JP-ноде)

```bash
br
# [1] Добавить новую страну в подписку
# Country code: jp
# ENTRY IP: 45.152.198.131
# ENTRY port: 8449
# SNI: rakuten.co.jp (auto)
```

CLI распечатает 3 JSON-блока и параметры Host. Также сохранит всё в `/opt/bridge-cli/etc/generated/jp.json`.

### Шаг 4 — Remnawave Panel

1. **Config Profiles → Edit Raw JSON**:
   - Вставить `VLESS_JP` в `inbounds[]`
   - Вставить `BRIDGE_JP` в `outbounds[]`
   - Вставить routing-rule в `routing.rules[]`
   - Save

2. **Hosts → New Host**:
   - Скопировать параметры (Address, Port, PublicKey, ShortId, SNI, FP)
   - **Mux: OFF** (обязательно — несовместим с Vision)
   - Save

### Шаг 5 — Подтверждение через probe

```bash
# Снова на ENTRY:
br
# [2] Тест ОДНОЙ exit-ноды → 45.67.89.10
```

Должно стать `✅ отлично`.

### Шаг 6 — Refresh подписки в Happp/v2rayNG

Клиенты подхватят новый Host автоматически или принудительно через pull-to-refresh.

---

## Транспорты (выбор при деплое)

При установке EXIT-ноды CLI спросит какой транспорт использовать:

| Транспорт | Применение |
|---|---|
| **Reality+TCP+Vision** | По умолчанию, стандартный. Маскирует трафик под TLS-сайт. |
| **Reality+xhttp** | Если клиенты Happp/sing-box страдают с UDP-DNS. xhttp туннелирует UDP в HTTP/2-стрим. |
| **WireGuard** | Plain WG-туннель. Без Reality-маскировки на участке Aeza→exit. Хорошо если этот участок не через DPI. |

---

## Multi-bridge на одной EXIT-ноде

CLI поддерживает **два сценария** подключения нескольких ENTRY-нод к одной EXIT:

- **Общий мост** (по умолчанию) — все ENTRY используют один UUID и порт. Проще.
- **Изолированный мост** — для каждой ENTRY поднимается отдельный контейнер `bridge-xray-N` на отдельном порту со своими ключами. Изоляция между проектами.

Выбирается в меню `[4] Подключить вторую ENTRY-ноду`.

---

## ENV-переменные

| Переменная | Где работает | Назначение |
|---|---|---|
| `BRIDGE_CREDS` | `install.sh` | base64-blob с ключами от первой EXIT |
| `XRAY_IMAGE` | везде | Переопределить docker-образ xray (default: `ghcr.io/xtls/xray-core:latest`) |
| `BRIDGE_CLI_HOME` | везде | Override каталога установки (default: `/opt/bridge-cli`) |
| `PING_COUNT` | probe | Сколько ping-пакетов (default: 10) |
| `BRIDGE_PORT` | `br probe` | Порт для проверки (default: 7443) |
| `BRIDGE_REALITY_SNI` | `br probe` | Ожидаемый SNI Reality (default: `max.ru`) |

---

## Где что лежит

```
/opt/bridge-cli/
├── bin/bridge-cli             # главный скрипт
├── lib/*.sh                   # модули
├── templates/                 # шаблоны конфигов
├── etc/state.json             # состояние (gitignored)
├── etc/generated/<cc>.json    # сохранённые блоки по странам
└── etc/probe-history/         # история тестов (10 дней)

/opt/bridge-xray/<bridge_name>/config.json  # config bridge-xray-контейнера
```

---

## Безопасность

- `state.json`, `preinit-creds.json`, `etc/generated/`, `etc/probe-history/` НЕ коммитятся в git (`.gitignore`)
- BRIDGE_CREDS — это секрет, не публикуйте
- Если ключи моста утекли → перегенерировать на одной EXIT-ноде, экспортировать новые creds, переустановить на всех остальных + обновить outbound-блоки в Remnawave Config Profile
- iperf3-сервер можно ограничить файрволом только IP ENTRY-нод (state.exit.iperf3.allowed_ips)

---

## Troubleshooting

### `br: command not found` после установки
Симлинк не создался. Проверь:
```bash
ls -la /usr/local/bin/br
ls -la /opt/bridge-cli/bin/bridge-cli
```

### `docker: command not found`
```bash
curl -fsSL https://get.docker.com | sh
```

### bridge-xray контейнер не запускается
```bash
docker logs bridge-xray-main
# часто: невалидный JSON в config.json, или порт занят
```

### probe показывает `✗ недоступен` но ping ОК
TCP/7443 закрыт. На EXIT-ноде:
```bash
ufw status | grep 7443
docker ps | grep bridge-xray
docker logs bridge-xray-main --tail 50
```

### probe показывает `⚠ чужой Reality`
Порт 7443 открыт, но отвечает не наш bridge-xray (другой сервис на этом порту). Освободить:
```bash
docker ps -a | grep 7443
# kill conflict, restart bridge-xray
```

### Клиент не видит сайтов после добавления Host в Remnawave
- Проверь что у Host **Mux: OFF** (Mux несовместим с Vision)
- Принудительно обнови подписку (pull-to-refresh)
- Проверь подписку: `curl 'https://<sub_url>'` — есть ли новый Host в base64

---

## Связанные проекты

- [Remnawave](https://github.com/remnawave/backend) — панель управления нодами
- [Xray-core](https://github.com/XTLS/Xray-core) — proxy-движок

## Лицензия

MIT.
