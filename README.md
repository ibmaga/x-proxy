# HAProxy SNI Router

TCP passthrough для нескольких Xray/VLESS Reality inbound'ов на одном порту 443.

HAProxy принимает все TLS-соединения на 443, читает SNI из ClientHello и маршрутизирует на нужный Xray inbound по домену.

```
клиент → 443/tcp (HAProxy, SNI inspect)
  ├─ SNI = layerzro.ru       → 127.0.0.1:10443 (Xray inbound)
  ├─ SNI = eh.vk.com         → /dev/shm/xray-eh.sock (unix socket)
  ├─ SNI = ads.x5.ru         → 127.0.0.1:10445 (Xray inbound)
  └─ default                 → 127.0.0.1:10444
```

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/ibmaga/x-proxy/main/setup.sh -o /usr/local/bin/haproxy-sni
chmod +x /usr/local/bin/haproxy-sni
```

## Использование

### Первая установка

```bash
haproxy-sni \
  --sni 'layerzro.ru:10443,eh.vk.com:10444,ads.x5.ru:10445' \
  --default 10444 \
  --stats
```

### Добавить/изменить SNI (без даунтайма)

Указываешь полный список SNI — скрипт перегенерирует конфиг и сделает `systemctl reload`:

```bash
haproxy-sni \
  --sni 'layerzro.ru:10443,eh.vk.com:10444,ads.x5.ru:10445,rutube.ru:10449' \
  --default 10444 \
  --stats \
  --apply-only
```

### Удалить HAProxy

```bash
haproxy-sni --uninstall
```

## Формат SNI записей

```
<домен>:<backend>[:<опции>]
```

**backend** — куда HAProxy проксирует:
- `10443` → `127.0.0.1:10443`
- `10.0.0.1:10443` → as-is
- `/dev/shm/xray.sock` → unix socket

**опции** (через `+`):
- По умолчанию все бэкенды получают `send-proxy` + `health check`
- `noproxy` — отключить PROXY protocol для этого бэкенда
- `nocheck` — отключить health check для этого бэкенда
- `proxy2` — использовать PROXY protocol v2 вместо v1

### Примеры

```bash
# Все бэкенды с send-proxy + health check (по умолчанию)
--sni 'layerzro.ru:10443,eh.vk.com:10444'

# Микс TCP портов и unix сокетов
--sni 'layerzro.ru:10443,eh.vk.com:/dev/shm/xray-eh.sock,ads.x5.ru:10445'

# Один бэкенд без proxy protocol
--sni 'layerzro.ru:10443,eh.vk.com:10444:noproxy'

# Один бэкенд без health check
--sni 'layerzro.ru:10443,eh.vk.com:10444:nocheck'

# PROXY protocol v2
--sni 'layerzro.ru:10443:proxy2'

# Комбинация опций
--sni 'layerzro.ru:10443:proxy2+nocheck'
```

## Health Check

Health check включён по умолчанию на всех бэкендах (`check inter 2000 fall 2 rise 2`).

При рестарте Xray HAProxy автоматически перестаёт слать трафик (бэкенд DOWN через 4 секунды) и возобновляет когда Xray поднимется (UP через 4 секунды). Порядок запуска не важен.

Параметры:
- `inter 2000` — проверка каждые 2 секунды
- `fall 2` — 2 неудачные проверки → бэкенд DOWN
- `rise 2` — 2 успешные проверки → бэкенд UP

Чтобы отключить для конкретного бэкенда — добавь `:nocheck`:

```bash
--sni 'layerzro.ru:10443,eh.vk.com:10444:nocheck'
```

### Добавить health check на уже запущенном HAProxy (без скрипта)

```bash
sudo sed -i 's/send-proxy$/send-proxy check inter 2000 fall 2 rise 2/g' /etc/haproxy/haproxy.cfg && \
haproxy -c -f /etc/haproxy/haproxy.cfg && \
systemctl reload haproxy
```

### Проверить статус бэкендов

```bash
# Через stats page (если включена)
curl -s http://localhost:8404/stats | grep -E "srv_|Status"

# Через CLI
echo "show servers state" | socat stdio /run/haproxy-master.sock
```

## Unix Socket vs TCP порт

Можно использовать unix socket вместо TCP порта для связи HAProxy ↔ Xray:

| | TCP порт | Unix socket |
|---|---|---|
| **Формат** | `eh.vk.com:10444` | `eh.vk.com:/dev/shm/xray-eh.sock` |
| **conntrack** | Создаёт запись | Нет |
| **Latency** | TCP overhead | Минимальный |
| **Порты** | Занимает порт | Не занимает |
| **Видимость** | Виден в `ss -tlnp` | Нет |

На 100K+ соединений unix socket экономит conntrack записи и CPU.

**Требования для unix socket:**
- В docker-compose remnanode добавить volume: `/dev/shm:/dev/shm`
- В Xray inbound: `"listen": "/dev/shm/xray-eh.sock,0666"` без `port`
- В HAProxy: `server srv /dev/shm/xray-eh.sock send-proxy`

## Настройка Xray inbound'ов

Каждый Xray inbound за HAProxy должен:
1. Слушать на `127.0.0.1` + локальный порт (или unix socket)
2. Иметь `acceptProxyProtocol: true` в `rawSettings`

### TCP порт

```json
{
  "tag": "my-inbound",
  "port": 10443,
  "listen": "127.0.0.1",
  "protocol": "vless",
  "streamSettings": {
    "network": "raw",
    "rawSettings": {
      "acceptProxyProtocol": true
    },
    "security": "reality",
    "realitySettings": {
      "target": "example.com:443",
      "serverNames": ["example.com"],
      "shortIds": ["fff8"],
      "privateKey": "..."
    }
  }
}
```

### Unix socket

```json
{
  "tag": "my-inbound",
  "listen": "/dev/shm/xray-eh.sock,0666",
  "protocol": "vless",
  "streamSettings": {
    "network": "raw",
    "rawSettings": {
      "acceptProxyProtocol": true
    },
    "security": "reality",
    "realitySettings": {
      "target": "example.com:443",
      "serverNames": ["example.com"],
      "shortIds": ["fff8"],
      "privateKey": "..."
    }
  }
}
```

> **Важно:** `send-proxy` в HAProxy и `acceptProxyProtocol: true` в Xray — всегда парой. Если одно есть, а другого нет — соединения будут дропаться.

## Все флаги

| Флаг | Описание | По умолчанию |
|------|----------|-------------|
| `--sni <entries>` | SNI записи через запятую (обязательно) | — |
| `--default <addr>` | Бэкенд для неизвестного SNI | reject |
| `--port <port>` | Порт для прослушивания | 443 |
| `--maxconn <n>` | Максимум соединений | авто по RAM |
| `--stats` | Включить stats на :8404 | выкл |
| `--stats-auth <user:pass>` | Авторизация stats | admin:haproxy |
| `--native` | Установка через apt | **по умолчанию** |
| `--docker` | Установка через Docker (host network) | — |
| `--apply-only` | Только обновить конфиг и reload | — |
| `--uninstall` | Удалить HAProxy | — |

## Мониторинг

Stats page доступна на `http://IP:8404/stats` (если включена).

Через SSH-туннель (если порт закрыт в UFW):

```bash
ssh -L 8404:localhost:8404 user@server-ip
# Открыть http://localhost:8404/stats в браузере
```

## Полезные команды

```bash
# Статус HAProxy
systemctl status haproxy

# Zero-downtime reload после изменения конфига
haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy

# Логи
journalctl -u haproxy -f

# Текущие соединения
ss -tlnp | grep haproxy
```
