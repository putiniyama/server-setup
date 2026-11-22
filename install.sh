#!/usr/bin/env bash
# Server setup script.
#   bash install.sh
# Optional env: DOMAIN, WG_PORT, ADMIN_USER, ADMIN_PASS
set -euo pipefail

INSTALL_DIR=/opt/panel
WG_PORT="${WG_PORT:-51820}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}"

green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
step() { echo; green "==> $*"; }

[ "$(id -u)" -eq 0 ] || { red "Запустите от root:  sudo bash install.sh"; exit 1; }
. /etc/os-release
if [ "${ID:-}" != "ubuntu" ]; then
  yellow "Внимание: скрипт проверен на Ubuntu 22.04/24.04, у вас ${PRETTY_NAME:-неизвестная ОС}."
  yellow "Модуль ядра может не установиться."
  sleep 5
fi
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------
step "1/6 Обновление пакетов и базовые утилиты"
apt-get update -y
apt-get install -y curl ca-certificates gnupg software-properties-common \
  "linux-headers-$(uname -r)" || apt-get install -y curl ca-certificates gnupg software-properties-common

# ---------------------------------------------------------------------
step "2/6 Установка Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# ---------------------------------------------------------------------
step "3/6 Установка модуля ядра"
AWG_OK=0
if [ "${ID:-}" = "ubuntu" ]; then
  # нужны включённые deb-src репозитории
  if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
  elif [ -f /etc/apt/sources.list ]; then
    sed -i 's/^# *deb-src/deb-src/' /etc/apt/sources.list
  fi
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update -y
  apt-get install -y amneziawg || true
fi
if modprobe amneziawg 2>/dev/null; then
  echo amneziawg > /etc/modules-load.d/amneziawg.conf
  AWG_OK=1
  green "Модуль ядра загружен."
else
  yellow "Модуль ядра не загрузился — будет использован стандартный режим."
fi

# ---------------------------------------------------------------------
step "4/6 Определение адреса сервера"
PUBLIC_IP="$(curl -4 -fsS https://api.ipify.org || curl -4 -fsS https://ifconfig.me)"
DOMAIN="${DOMAIN:-${PUBLIC_IP//./-}.sslip.io}"
echo "IP сервера: $PUBLIC_IP"
echo "Адрес панели: https://$DOMAIN"

# ---------------------------------------------------------------------
step "5/6 Настройка фаервола"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow "${WG_PORT}/udp"
  green "Правила ufw добавлены."
else
  echo "ufw не активен — пропускаю. Если у хостера есть свой фаервол в панели,"
  echo "откройте там порты: 22/tcp, 80/tcp, 443/tcp, ${WG_PORT}/udp"
fi

# ---------------------------------------------------------------------
step "6/6 Запуск"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

cat > Caddyfile <<EOF
$DOMAIN {
    reverse_proxy wg-easy:51821
}
EOF

write_compose() {
  local with_init="$1"
  cat > docker-compose.yml <<EOF
volumes:
  etc_wireguard:
  caddy_data:
  caddy_config:

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    environment:
      - EXPERIMENTAL_AWG=true
EOF
  if [ "$with_init" = "1" ]; then
    cat >> docker-compose.yml <<EOF
      - INIT_ENABLED=true
      - INIT_USERNAME=$ADMIN_USER
      - INIT_PASSWORD=$ADMIN_PASS
      - INIT_HOST=$PUBLIC_IP
      - INIT_PORT=$WG_PORT
      - INIT_DNS=1.1.1.1,8.8.8.8
EOF
  fi
  cat >> docker-compose.yml <<EOF
    networks:
      wg:
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "$WG_PORT:$WG_PORT/udp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1

  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    depends_on:
      - wg-easy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - wg

networks:
  wg:
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
        - subnet: fdcc:ad94:bacf:61a3::/64
EOF
  chmod 600 docker-compose.yml
}

FIRST_RUN=0
if ! docker volume ls --format '{{.Name}}' | grep -q 'panel_etc_wireguard'; then
  FIRST_RUN=1
fi

write_compose "$FIRST_RUN"
docker compose pull
docker compose up -d

if [ "$FIRST_RUN" = "1" ]; then
  echo "Жду, пока панель запустится..."
  for _ in $(seq 1 60); do
    curl -fs -o /dev/null http://10.42.42.42:51821/ && break
    sleep 2
  done
  sleep 5
  # Убираем пароль из конфигурации — он нужен только при первом запуске
  write_compose 0
  docker compose up -d
fi

CRED_FILE=/root/panel-credentials.txt
if [ "$FIRST_RUN" = "1" ]; then
  cat > "$CRED_FILE" <<EOF
Панель:  https://$DOMAIN
Логин:   $ADMIN_USER
Пароль:  $ADMIN_PASS
Порт:    $PUBLIC_IP:$WG_PORT/udp
Модуль:  $([ "$AWG_OK" = 1 ] && echo "да" || echo "нет")
EOF
  chmod 600 "$CRED_FILE"
fi

echo
green "=============================================================="
green "  ГОТОВО!"
green "=============================================================="
if [ "$FIRST_RUN" = "1" ]; then
  cat "$CRED_FILE"
  echo
  echo "Эти данные сохранены в $CRED_FILE"
else
  echo "Панель уже была установлена ранее, обновлена до свежей версии."
  echo "Панель: https://$DOMAIN  (логин/пароль — в $CRED_FILE)"
fi
echo
echo "Если панель не открывается сразу — подождите 1-2 минуты,"
echo "сервер получает HTTPS-сертификат."
