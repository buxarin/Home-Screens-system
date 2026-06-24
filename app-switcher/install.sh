#!/bin/bash
# =============================================================================
#  App Switcher — установщик переключателя Home Screens ↔ Home Assistant
#
#  Запуск:   sudo ./install.sh
#  Удаление: sudo ./install.sh --uninstall
#
#  Что делает:
#   • Устанавливает nginx + python3-evdev + python3-websocket
#   • Помещает конфиг nginx в /etc/nginx/conf.d/kiosk-switcher.conf
#   • Устанавливает демон kiosk-switcher.py как systemd-сервис
#   • Настраивает HA trusted_proxies
#   • Меняет PORT киоска на 8080 (через port.conf)
#
#  После установки:
#   • Одно касание правого верхнего угла → переключение между приложениями
#   • Home Screens:    http://localhost:8080
#   • Home Assistant:  http://localhost:8081
# =============================================================================
set -euo pipefail

CONF_NAME="kiosk-switcher"
CONF_DST="/etc/nginx/conf.d/${CONF_NAME}.conf"
SWITCHER_BIN="/usr/local/bin/kiosk-switcher.py"
SWITCHER_SVC="/etc/systemd/system/kiosk-switcher.service"
HA_CONFIG_DIR="/opt/homeassistant"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC}  $1"; }
ok(){   echo -e "${GREEN}[OK]${NC}    $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC}  $1"; }
err(){  echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step(){ echo -e "\n${CYAN}▸ $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${REAL_USER:-pi}"
PYTHON3_BIN="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"

check_root() { [ "$EUID" -eq 0 ] || err "Запустите через sudo."; }

# ── Find kiosk launcher ───────────────────────────────────────────────────────
find_kiosk_launcher() {
  for f in \
      /opt/home-screens/current/scripts/kiosk-launcher.sh \
      /home/pi/home-screens/scripts/kiosk-launcher.sh \
      /opt/home-screens/scripts/kiosk-launcher.sh; do
    [ -f "$f" ] && { echo "$f"; return; }
  done

  # search broadly
  find /opt /home -name "kiosk-launcher.sh" 2>/dev/null | head -1
}

# ── Patch kiosk URL via port.conf ────────────────────────────────────────────
# kiosk-launcher.sh reads PORT from data/port.conf and opens
# http://localhost:${PORT}/display  — we point it at our nginx proxy (8080).
patch_kiosk_url() {
  local launcher
  launcher="$(find_kiosk_launcher)"

  if [ -z "$launcher" ]; then
    warn "kiosk-launcher.sh не найден — порт не изменён"
    return
  fi

  local app_dir
  app_dir="$(dirname "$(dirname "$launcher")")"
  local port_conf="${app_dir}/data/port.conf"

  info "Kiosk launcher: $launcher"
  info "port.conf: $port_conf"

  # Back up original port if not already done
  if [ ! -f "${port_conf}.orig" ] && [ -f "$port_conf" ]; then
    cp "$port_conf" "${port_conf}.orig"
  fi

  echo "8080" > "$port_conf"
  chown "${REAL_USER}:${REAL_USER}" "$port_conf" 2>/dev/null || true
  ok "port.conf установлен на 8080 (kiosk будет открывать nginx proxy)"
}

# ── Patch HA configuration.yaml (trusted_proxies) ────────────────────────────
patch_ha_config() {
  local ha_cfg="${HA_CONFIG_DIR}/configuration.yaml"
  if [ ! -f "$ha_cfg" ]; then
    warn "HA configuration.yaml не найден ($ha_cfg) — пропускаем настройку"
    return
  fi

  # Proxy trust (needed for correct IP forwarding)
  if ! grep -q "trusted_proxies" "$ha_cfg"; then
    cat >> "$ha_cfg" <<'YAML'

# nginx reverse proxy (app-switcher)
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
YAML
    ok "HA trusted_proxies добавлен"
  else
    info "trusted_proxies уже настроен"
  fi

  # Auto-login from local network (kiosk — no keyboard available)
  if ! grep -q "trusted_networks" "$ha_cfg"; then
    cat >> "$ha_cfg" <<'YAML'

# Auto-login for kiosk (no keyboard): anyone on local network logs in automatically
homeassistant:
  auth_providers:
    - type: trusted_networks
      trusted_networks:
        - 127.0.0.1
        - 192.168.0.0/16
        - 10.0.0.0/8
        - 172.16.0.0/12
      allow_bypass_login: true
    - type: homeassistant
YAML
    ok "HA trusted_networks (авто-логин) добавлен"
    warn "Перезапустите HA: sudo docker restart homeassistant"
    warn "ВАЖНО: сначала завершите онбординг HA с другого устройства (телефон/ноутбук)"
    warn "  Откройте: http://$(hostname -I | awk '{print $1}'):8081"
  else
    info "trusted_networks уже настроен"
  fi
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
do_uninstall() {
  step "Удаление App Switcher"

  systemctl stop  kiosk-switcher 2>/dev/null || true
  systemctl disable kiosk-switcher 2>/dev/null || true
  rm -f "$SWITCHER_SVC" "$SWITCHER_BIN"
  systemctl daemon-reload 2>/dev/null || true
  ok "Демон kiosk-switcher удалён"

  rm -f "$CONF_DST"
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
  ok "Конфиг nginx удалён"

  local launcher
  launcher="$(find_kiosk_launcher)"
  if [ -n "$launcher" ]; then
    local app_dir port_conf
    app_dir="$(dirname "$(dirname "$launcher")")"
    port_conf="${app_dir}/data/port.conf"
    if [ -f "${port_conf}.orig" ]; then
      mv "${port_conf}.orig" "$port_conf"
      ok "port.conf восстановлен"
    elif [ -f "$port_conf" ] && [ "$(cat "$port_conf")" = "8080" ]; then
      echo "3000" > "$port_conf"
      ok "port.conf возвращён на 3000"
    fi
  fi
  exit 0
}

# ── Install touch-switcher daemon ─────────────────────────────────────────────
install_switcher_daemon() {
  step "Установка зависимостей Python (evdev, websocket)"
  apt-get install -y python3-evdev python3-websocket 2>/dev/null \
    || pip3 install evdev websocket-client 2>/dev/null \
    || warn "Не удалось установить зависимости — установите вручную: sudo apt-get install python3-evdev python3-websocket"

  step "Установка kiosk-switcher.py"
  [ -f "$SCRIPT_DIR/kiosk-switcher.py" ] || err "kiosk-switcher.py не найден"
  install -m 0755 "$SCRIPT_DIR/kiosk-switcher.py" "$SWITCHER_BIN"
  ok "Демон установлен: $SWITCHER_BIN"

  step "Установка systemd сервиса"
  [ -f "$SCRIPT_DIR/kiosk-switcher.service" ] || err "kiosk-switcher.service не найден"
  install -m 0644 "$SCRIPT_DIR/kiosk-switcher.service" "$SWITCHER_SVC"
  systemctl daemon-reload
  systemctl enable kiosk-switcher
  systemctl restart kiosk-switcher && ok "kiosk-switcher.service запущен" \
    || warn "Сервис не запустился — проверьте: journalctl -u kiosk-switcher -n 30"
}

# ── Main install ──────────────────────────────────────────────────────────────
do_install() {
  step "Установка nginx (если отсутствует)"
  if ! command -v nginx &>/dev/null; then
    apt-get update -q && apt-get install -y nginx
    ok "nginx установлен"
  else
    ok "nginx уже установлен: $(nginx -v 2>&1)"
  fi

  step "Установка nginx конфига"
  [ -f "$SCRIPT_DIR/nginx-kiosk.conf" ] || err "nginx-kiosk.conf не найден рядом со скриптом"

  # Disable default nginx site to free port 80 conflict (optional, doesn't affect 8080/8081)
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  install -m 0644 "$SCRIPT_DIR/nginx-kiosk.conf" "$CONF_DST"
  ok "Конфиг скопирован в $CONF_DST"

  step "Проверка конфига nginx"
  nginx -t || err "Ошибка в конфиге nginx — проверьте $CONF_DST"

  step "Перезапуск nginx"
  if command -v systemctl &>/dev/null && systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx && ok "nginx перезагружен"
  else
    systemctl enable nginx 2>/dev/null || true
    systemctl start nginx  2>/dev/null || service nginx restart 2>/dev/null || nginx
    ok "nginx запущен"
  fi

  step "Настройка Home Assistant (trusted_proxies)"
  patch_ha_config

  step "Обновление kiosk launcher URL"
  patch_kiosk_url

  install_switcher_daemon
}

main() {
  case "${1:-}" in
    --uninstall|-u) check_root; do_uninstall ;;
    --help|-h)
      echo "Использование: sudo ./install.sh [--uninstall]"
      echo "Переменные:  REAL_USER=pi  HA_CONFIG_DIR=/opt/homeassistant"
      exit 0 ;;
    ""|--install) ;;
    *) err "Неизвестный флаг: $1" ;;
  esac

  check_root
  echo -e "${BLUE}App Switcher — установка${NC}"
  do_install

  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  App Switcher установлен!${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
  echo "  Home Screens  → http://localhost:8080"
  echo "  Home Assistant → http://localhost:8081"
  echo ""
  echo "  Одно касание правого верхнего угла (18% × 14% экрана)"
  echo "  переключает между приложениями."
  echo ""
  echo "  Статус демона : sudo systemctl status kiosk-switcher"
  echo "  Логи          : sudo journalctl -u kiosk-switcher -f"
  echo ""
  echo "  Если HA показывает ошибку авторизации через прокси:"
  echo "    sudo docker restart homeassistant"
  echo ""
}

main "$@"
