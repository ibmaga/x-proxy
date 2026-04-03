#!/usr/bin/env bash
# =============================================================================
# 
#  
#
#  Usage:
#    bash haproxy-sni-install.sh --sni "layerzro.ru:10443,eh.vk.com:10444"
#    bash haproxy-sni-install.sh --sni "layerzro.ru:10443,eh.vk.com:10444" --default 10443 --stats
#
#  Формат SNI записей (через запятую):
#    <sni_domain>:<backend_addr>[:<options>]
#
#  backend_addr:
#    - порт (10443)               → 127.0.0.1:10443
#    - ip:port (10.0.0.1:10443)   → as-is
#    - unix socket path            → /dev/shm/xray-self.sock
#
#  options (через +):
#    - noproxy  → НЕ отправлять PROXY protocol (по умолчанию send-proxy включён)
#    - proxy2   → send-proxy-v2 вместо v1
#    - check    → enable health check
#
#  По умолчанию ВСЕ бэкенды получают send-proxy (PROXY protocol v1).
#  Xray inbound должен иметь acceptProxyProtocol: true в rawSettings/tcpSettings.
#
#  Flags:
#    --sni <entries>           SNI routing entries (required)
#    --default <addr>          Default backend (no SNI match). Default: reject
#    --port <port>             Listen port (default: 443)
#    --maxconn <n>             Global maxconn (default: auto by RAM)
#    --stats                   Enable stats page on :8404/stats
#    --stats-auth <user:pass>  Stats auth (default: admin:haproxy)
#    --native                  Install HAProxy natively via apt (default)
#    --docker                  Run HAProxy in Docker (network_mode: host)
#    --apply-only              Regenerate config only, don't install
#    --uninstall               Remove HAProxy completely
#    -h, --help                Show usage
#
#  Author: ibmaga
# =============================================================================
set -euo pipefail

# ── Цвета ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; GRAY='\033[0;90m'; WHITE='\033[1;37m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}━━━━━━━━━  $*  ━━━━━━━━━${NC}"; }

# ── Дефолты ───────────────────────────────────────────────────────
HAPROXY_DIR="/opt/haproxy"
HAPROXY_CFG="${HAPROXY_DIR}/haproxy.cfg"
LISTEN_PORT=443
SNI_ENTRIES=""
DEFAULT_BACKEND=""
MAXCONN=""
ENABLE_STATS=false
STATS_AUTH="admin:haproxy"
INSTALL_MODE="native"
APPLY_ONLY=false
UNINSTALL=false

# ── Парсинг аргументов ────────────────────────────────────────────
show_usage() {
    echo "Usage: $0 --sni <entries> [options]"
    echo ""
    echo "SNI entry format: <domain>:<backend>[:<options>]"
    echo "  backend: port | ip:port | /path/to/socket"
    echo "  options: noproxy, proxy2, check (combine with +)"
    echo ""
    echo "  По умолчанию все бэкенды получают send-proxy (PROXY protocol v1)."
    echo "  Используй :noproxy чтобы отключить для конкретного бэкенда."
    echo "  Используй :proxy2 для PROXY protocol v2."
    echo ""
    echo "Options:"
    echo "  --sni <entries>           Comma-separated SNI entries (required)"
    echo "  --default <addr>          Default backend for unmatched SNI"
    echo "  --port <port>             Listen port (default: 443)"
    echo "  --maxconn <n>             Global maxconn (auto if omitted)"
    echo "  --stats                   Enable stats on :8404/stats"
    echo "  --stats-auth <user:pass>  Stats credentials (default: admin:haproxy)"
    echo "  --native                  Install via apt (default)"
    echo "  --docker                  Run in Docker (network_mode: host)"
    echo "  --apply-only              Regenerate config, restart, no install"
    echo "  --uninstall               Remove HAProxy"
    echo "  -h, --help                Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --sni 'layerzro.ru:10443,eh.vk.com:10444' --default 10443 --stats"
    echo "  $0 --sni 'my.domain.com:10443:proxy2,other.com:10444:noproxy'"
    echo ""
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --sni)          SNI_ENTRIES="$2"; shift 2 ;;
        --default)      DEFAULT_BACKEND="$2"; shift 2 ;;
        --port)         LISTEN_PORT="$2"; shift 2 ;;
        --maxconn)      MAXCONN="$2"; shift 2 ;;
        --stats)        ENABLE_STATS=true; shift ;;
        --stats-auth)   STATS_AUTH="$2"; shift 2 ;;
        --native)       INSTALL_MODE="native"; shift ;;
        --docker)       INSTALL_MODE="docker"; shift ;;
        --apply-only)   APPLY_ONLY=true; shift ;;
        --uninstall)    UNINSTALL=true; shift ;;
        -h|--help)      show_usage; exit 0 ;;
        *)              error "Unknown option: $1. Use --help" ;;
    esac
done

[[ $EUID -ne 0 ]] && error "Запусти от root"

# ── Uninstall ─────────────────────────────────────────────────────
if [[ "$UNINSTALL" == "true" ]]; then
    section "Удаление HAProxy"
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        cd "${HAPROXY_DIR}" 2>/dev/null && docker compose down 2>/dev/null || true
        docker rm -f haproxy-sni 2>/dev/null || true
    else
        systemctl stop haproxy 2>/dev/null || true
        systemctl disable haproxy 2>/dev/null || true
        apt-get remove -y haproxy 2>/dev/null || true
    fi
    info "HAProxy остановлен и удалён"
    info "Конфиг сохранён в ${HAPROXY_DIR}/ (удали вручную если не нужен)"
    exit 0
fi

[[ -z "$SNI_ENTRIES" ]] && { show_usage; error "Не указаны SNI записи. Используй --sni"; }

# ── Автоопределение maxconn ───────────────────────────────────────
calc_maxconn() {
    local ram_gb
    ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    if (( ram_gb <= 2 )); then
        echo 50000
    elif (( ram_gb <= 4 )); then
        echo 100000
    elif (( ram_gb <= 8 )); then
        echo 200000
    else
        echo 300000
    fi
}

if [[ -z "$MAXCONN" ]]; then
    MAXCONN=$(calc_maxconn)
fi

# ── Определение CPU ───────────────────────────────────────────────
NBTHREAD=$(nproc)

# ── Парсинг SNI записей ──────────────────────────────────────────
declare -a SNI_DOMAINS=()
declare -a SNI_BACKENDS=()
declare -a SNI_OPTIONS=()

parse_sni_entries() {
    IFS=',' read -ra ENTRIES <<< "$SNI_ENTRIES"
    for entry in "${ENTRIES[@]}"; do
        entry=$(echo "$entry" | xargs)
        [[ -z "$entry" ]] && continue

        local domain backend options=""

        domain="${entry%%:*}"
        local rest="${entry#*:}"

        if [[ "$rest" == /* ]]; then
            if [[ "$rest" == *:* ]]; then
                backend="${rest%:*}"
                options="${rest##*:}"
            else
                backend="$rest"
            fi
        else
            local colon_count
            colon_count=$(echo "$rest" | tr -cd ':' | wc -c)

            if (( colon_count == 0 )); then
                backend="127.0.0.1:${rest}"
            elif (( colon_count == 1 )); then
                local part1="${rest%%:*}"
                local part2="${rest#*:}"
                if [[ "$part1" =~ ^[0-9]+$ ]] && ! [[ "$part2" =~ ^[0-9]+$ ]]; then
                    backend="127.0.0.1:${part1}"
                    options="$part2"
                else
                    backend="${rest}"
                fi
            else
                local ip_port="${rest%:*}"
                options="${rest##*:}"
                backend="$ip_port"
            fi
        fi

        [[ -z "$domain" ]] && error "Пустой домен в записи: $entry"
        [[ -z "$backend" ]] && error "Пустой backend в записи: $entry"

        SNI_DOMAINS+=("$domain")
        SNI_BACKENDS+=("$backend")
        SNI_OPTIONS+=("$options")
    done

    if [[ ${#SNI_DOMAINS[@]} -eq 0 ]]; then
        error "Не удалось распарсить SNI записи"
    fi
}

parse_sni_entries

# Нормализуем default backend
if [[ -n "$DEFAULT_BACKEND" ]]; then
    if [[ "$DEFAULT_BACKEND" =~ ^[0-9]+$ ]]; then
        DEFAULT_BACKEND="127.0.0.1:${DEFAULT_BACKEND}"
    fi
fi

# ── Хелпер: отображение proxy-режима ──
get_proxy_display() {
    local opts="$1"
    if [[ -n "$opts" ]]; then
        IFS='+' read -ra OPT_ARRAY <<< "$opts"
        for opt in "${OPT_ARRAY[@]}"; do
            [[ "$opt" == "noproxy" ]] && echo "no proxy" && return
            [[ "$opt" == "proxy2" ]] && echo "send-proxy-v2" && return
        done
    fi
    echo "send-proxy"
}

# ══════════════════════════════════════════════════════════════════
section "Конфигурация"
# ══════════════════════════════════════════════════════════════════
echo -e "  Listen:     ${GREEN}*:${LISTEN_PORT}${NC}"
echo -e "  maxconn:    ${GREEN}${MAXCONN}${NC}"
echo -e "  nbthread:   ${GREEN}${NBTHREAD}${NC}"
echo -e "  Mode:       ${GREEN}${INSTALL_MODE}${NC}"
echo -e "  Stats:      ${GREEN}${ENABLE_STATS}${NC}"
echo ""
echo -e "  ${WHITE}SNI → Backend:${NC}"
for i in "${!SNI_DOMAINS[@]}"; do
    local_proxy=$(get_proxy_display "${SNI_OPTIONS[$i]}")
    echo -e "    ${CYAN}${SNI_DOMAINS[$i]}${NC} → ${GREEN}${SNI_BACKENDS[$i]}${NC}  [${local_proxy}]"
done
if [[ -n "$DEFAULT_BACKEND" ]]; then
    echo -e "    ${CYAN}(default)${NC} → ${GREEN}${DEFAULT_BACKEND}${NC}  [send-proxy]"
else
    echo -e "    ${CYAN}(default)${NC} → ${YELLOW}reject${NC}"
fi
echo ""

# ══════════════════════════════════════════════════════════════════
section "1. Создание директорий"
# ══════════════════════════════════════════════════════════════════
mkdir -p "${HAPROXY_DIR}"
info "Директория: ${HAPROXY_DIR}/"

# ══════════════════════════════════════════════════════════════════
section "2. Генерация haproxy.cfg"
# ══════════════════════════════════════════════════════════════════

generate_server_line() {
    local name="$1"
    local addr="$2"
    local opts="$3"
    local line="    server ${name} ${addr}"

    local has_noproxy=false
    local has_proxy2=false
    local has_check=false

    if [[ -n "$opts" ]]; then
        IFS='+' read -ra OPT_ARRAY <<< "$opts"
        for opt in "${OPT_ARRAY[@]}"; do
            case "$opt" in
                noproxy) has_noproxy=true ;;
                proxy2)  has_proxy2=true ;;
                check)   has_check=true ;;
            esac
        done
    fi

    if [[ "$has_noproxy" == "false" ]]; then
        if [[ "$has_proxy2" == "true" ]]; then
            line+=" send-proxy-v2"
        else
            line+=" send-proxy"
        fi
    fi

    [[ "$has_check" == "true" ]] && line+=" check"

    echo "$line"
}

{
cat << 'GLOBAL_EOF'
# ═══════════════════════════════════════════════════════════════
#  HAProxy SNI Router — TCP passthrough для Xray/VLESS Reality
#  Generated by haproxy-sni-install.sh
# ═══════════════════════════════════════════════════════════════

global
GLOBAL_EOF

echo "    maxconn ${MAXCONN}"
echo "    nbthread ${NBTHREAD}"

cat << 'GLOBAL2_EOF'
    log /dev/log local0 info
    log /dev/log local1 notice

    # Производительность
    tune.maxaccept 256
    tune.bufsize 16384
    tune.idle-pool.shared on

defaults
    mode tcp
    log global
    option dontlognull
    option tcp-smart-accept
    option tcp-smart-connect
    option splice-auto

    timeout connect 5s
    timeout client 300s
    timeout server 300s
    timeout tunnel 1h
    timeout client-fin 30s
    timeout server-fin 30s

    retries 3
    option redispatch

GLOBAL2_EOF

if [[ "$ENABLE_STATS" == "true" ]]; then
cat << STATS_EOF
frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats show-legends
    stats show-node
    stats auth ${STATS_AUTH}

STATS_EOF
fi

cat << FRONT_EOF
# ── SNI routing ───────────────────────────────────────────────
frontend ft_sni
    bind *:${LISTEN_PORT}
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

FRONT_EOF

for i in "${!SNI_DOMAINS[@]}"; do
    local_name=$(echo "${SNI_DOMAINS[$i]}" | tr '.' '_' | tr '-' '_')
    echo "    use_backend bk_${local_name} if { req.ssl_sni -i ${SNI_DOMAINS[$i]} }"
done

if [[ -n "$DEFAULT_BACKEND" ]]; then
    echo "    default_backend bk_default"
fi

echo ""
echo "# ── Backends ────────────────────────────────────────────────"

for i in "${!SNI_DOMAINS[@]}"; do
    local_name=$(echo "${SNI_DOMAINS[$i]}" | tr '.' '_' | tr '-' '_')
    echo ""
    echo "backend bk_${local_name}"
    echo "    mode tcp"
    generate_server_line "srv_${local_name}" "${SNI_BACKENDS[$i]}" "${SNI_OPTIONS[$i]}"
done

if [[ -n "$DEFAULT_BACKEND" ]]; then
    echo ""
    echo "backend bk_default"
    echo "    mode tcp"
    echo "    server srv_default ${DEFAULT_BACKEND} send-proxy"
fi

} > "${HAPROXY_CFG}"

info "haproxy.cfg → ${HAPROXY_CFG}"

if command -v haproxy &>/dev/null; then
    if haproxy -c -f "${HAPROXY_CFG}" >/dev/null 2>&1; then
        info "Конфигурация валидна"
    else
        warn "Ошибка валидации:"
        haproxy -c -f "${HAPROXY_CFG}" 2>&1 || true
    fi
fi

# ══════════════════════════════════════════════════════════════════
#  Apply-only
# ══════════════════════════════════════════════════════════════════
if [[ "$APPLY_ONLY" == "true" ]]; then
    section "Применение конфигурации"
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        cd "${HAPROXY_DIR}"
        if docker compose ps 2>/dev/null | grep -q haproxy; then
            docker compose restart
            info "HAProxy перезапущен"
        else
            warn "Контейнер не запущен. Запусти: cd ${HAPROXY_DIR} && docker compose up -d"
        fi
    else
        cp "${HAPROXY_CFG}" /etc/haproxy/haproxy.cfg
        if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
            systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
            info "HAProxy перезагружен (zero-downtime reload)"
        else
            error "Конфиг невалиден, reload отменён"
        fi
    fi
    exit 0
fi

# ══════════════════════════════════════════════════════════════════
section "3. Установка HAProxy"
# ══════════════════════════════════════════════════════════════════

CURRENT_PORT=$(ss -tlnp | grep ":${LISTEN_PORT} " | head -1 || true)
if [[ -n "$CURRENT_PORT" ]]; then
    warn "Порт ${LISTEN_PORT} занят:"
    echo -e "  ${GRAY}${CURRENT_PORT}${NC}"
    warn "Перенеси Xray inbound'ы на локальные порты перед запуском."
    echo ""
    read -rp "$(echo -e "${YELLOW}Продолжить? (y/N): ${NC}")" CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Конфиг: ${HAPROXY_CFG}. Освободи порт и запусти HAProxy."
        exit 0
    fi
fi

if [[ "$INSTALL_MODE" == "native" ]]; then
    apt-get update -qq
    apt-get install -y -qq haproxy

    [[ -f /etc/haproxy/haproxy.cfg ]] && \
        cp /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.bak.$(date +%s)"

    cp "${HAPROXY_CFG}" /etc/haproxy/haproxy.cfg

    mkdir -p /etc/systemd/system/haproxy.service.d/
    cat > /etc/systemd/system/haproxy.service.d/limits.conf << 'LIMEOF'
[Service]
LimitNOFILE=1048576
LIMEOF

    systemctl daemon-reload
    systemctl enable haproxy

    if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
        systemctl restart haproxy
        sleep 1
        if systemctl is-active --quiet haproxy; then
            info "HAProxy запущен (native)"
        else
            warn "HAProxy не стартовал: journalctl -u haproxy -n 20"
        fi
    else
        warn "Конфиг невалиден:"
        haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1 || true
    fi

else
    command -v docker &>/dev/null || error "Docker не установлен. Используй --native."

    cat > "${HAPROXY_DIR}/docker-compose.yml" << DCEOF
services:
  haproxy-sni:
    image: haproxy:3.1-alpine
    container_name: haproxy-sni
    hostname: haproxy-sni
    restart: always
    network_mode: host
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
      - /dev/shm:/dev/shm:rw
    logging:
      driver: json-file
      options:
        max-size: 30m
        max-file: "3"
DCEOF

    cd "${HAPROXY_DIR}"
    docker compose pull -q
    docker compose up -d

    sleep 2
    if docker compose ps 2>/dev/null | grep -q "running\|Up"; then
        info "HAProxy запущен (Docker, host network)"
    else
        warn "HAProxy не стартовал. Логи: docker compose logs"
    fi
fi

# ══════════════════════════════════════════════════════════════════
section "4. Firewall"
# ══════════════════════════════════════════════════════════════════
if command -v ufw &>/dev/null; then
    ufw allow "${LISTEN_PORT}/tcp" comment 'HAProxy SNI' > /dev/null 2>&1 || true
    [[ "$ENABLE_STATS" == "true" ]] && \
        ufw allow 8404/tcp comment 'HAProxy Stats' > /dev/null 2>&1 || true
    info "UFW: порт ${LISTEN_PORT} открыт"
fi

# ══════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          HAProxy SNI Router установлен!                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${WHITE}Маршрутизация:${NC}"
for i in "${!SNI_DOMAINS[@]}"; do
    local_proxy=$(get_proxy_display "${SNI_OPTIONS[$i]}")
    echo -e "    ${CYAN}${SNI_DOMAINS[$i]}${NC} → ${GREEN}${SNI_BACKENDS[$i]}${NC}  [${local_proxy}]"
done
[[ -n "$DEFAULT_BACKEND" ]] && \
    echo -e "    ${CYAN}(default)${NC} → ${GREEN}${DEFAULT_BACKEND}${NC}  [send-proxy]"
echo ""

if [[ "$ENABLE_STATS" == "true" ]]; then
    SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "SERVER_IP")
    echo -e "  ${WHITE}Stats:${NC} http://${SERVER_IP}:8404/stats (${STATS_AUTH})"
    echo ""
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  Xray inbound'ы должны:${NC}"
echo -e "${YELLOW}  1. listen: \"127.0.0.1\" + локальный порт${NC}"
echo -e "${YELLOW}  2. acceptProxyProtocol: true в rawSettings/tcpSettings${NC}"
echo ""
for i in "${!SNI_DOMAINS[@]}"; do
    local_backend="${SNI_BACKENDS[$i]}"
    local_proxy=$(get_proxy_display "${SNI_OPTIONS[$i]}")
    if [[ "$local_backend" == /* ]]; then
        echo -e "  ${CYAN}${SNI_DOMAINS[$i]}${NC}: listen: \"${local_backend}\"  [${local_proxy}]"
    else
        local_port="${local_backend##*:}"
        local_ip="${local_backend%%:*}"
        echo -e "  ${CYAN}${SNI_DOMAINS[$i]}${NC}: port: ${local_port}, listen: \"${local_ip}\"  [${local_proxy}]"
    fi
done
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
if [[ "$INSTALL_MODE" == "native" ]]; then
    echo -e "${GRAY}Статус:   systemctl status haproxy${NC}"
    echo -e "${GRAY}Reload:   systemctl reload haproxy${NC}"
    echo -e "${GRAY}Логи:     journalctl -u haproxy -f${NC}"
else
    echo -e "${GRAY}Логи:     docker compose -f ${HAPROXY_DIR}/docker-compose.yml logs -f${NC}"
    echo -e "${GRAY}Рестарт:  docker compose -f ${HAPROXY_DIR}/docker-compose.yml restart${NC}"
fi
echo -e "${GRAY}Обновить: $0 --sni '...' --apply-only${NC}"
echo ""
