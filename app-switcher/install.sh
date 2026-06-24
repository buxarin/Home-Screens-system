#!/bin/bash
# =============================================================================
#  App Switcher — установщик переключателя Home Screens ↔ Home Assistant
#
#  Запуск:   sudo ./install.sh
#  Удаление: sudo ./install.sh --uninstall
#
#  Что делает:
#   • Устанавливает nginx (если ещё нет)
#   • Помещает конфиг kiosk-switcher.conf в /etc/nginx/conf.d/
#   • Настраивает HA trusted_proxies (разрешает проксирование через nginx)
#   • Меняет URL запуска киоска на http://localhost:8080 (Home Screens через прокси)
#   • Перезапускает nginx и home-screens.service
#
#  После установки:
#   • Два пальца в правый верхний угол → переключение между приложениями
#   • Home Screens:   http://localhost:8080
#   • Home Assistant: http://localhost:8081
# =============================================================================
set -euo pipefail

CONF_NAME="kiosk-switcher"
CONF_DST="/etc/nginx/conf.d/${CONF_NAME}.conf"
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

# ── Patch kiosk URL ───────────────────────────────────────────────────────────
patch_kiosk_url() {
  local launcher
  launcher="$(find_kiosk_launcher)"

  if [ -z "$launcher" ]; then
    warn "kiosk-launcher.sh не найден — измените URL запуска вручную на http://localhost:8080"
    return
  fi

  info "Kiosk launcher: $launcher"

  # Replace the URL used to open chromium; support port 3000 or bare hostname
  if grep -q "localhost:3000\|127\.0\.0\.1:3000" "$launcher"; then
    sed -i 's|http://localhost:3000|http://localhost:8080|g;
            s|http://127\.0\.0\.1:3000|http://localhost:8080|g' "$launcher"
    ok "URL в кiosк-launcher.sh изменён на http://localhost:8080"
  else
    warn "Не нашёл 'localhost:3000' в $launcher — проверьте вручную"
    grep -n "http://" "$launcher" | head -5 || true
  fi
}

# ── Patch HA configuration.yaml (trusted_proxies) ────────────────────────────
patch_ha_config() {
  local ha_cfg="${HA_CONFIG_DIR}/configuration.yaml"
  if [ ! -f "$ha_cfg" ]; then
    warn "HA configuration.yaml не найден ($ha_cfg) — пропускаем настройку trusted_proxies"
    return
  fi

  if grep -q "trusted_proxies" "$ha_cfg"; then
    info "trusted_proxies уже настроен в HA"
    return
  fi

  cat >> "$ha_cfg" <<'YAML'

# Allow nginx reverse proxy (app-switcher)
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
YAML
  ok "HA trusted_proxies добавлен в $ha_cfg"
  info "Перезапустите Home Assistant: sudo docker restart homeassistant"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
do_uninstall() {
  step "Удаление App Switcher"
  rm -f "$CONF_DST"
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
  ok "Конфиг nginx удалён"

  local launcher
  launcher="$(find_kiosk_launcher)"
  if [ -n "$launcher" ] && grep -q "localhost:8080" "$launcher"; then
    sed -i 's|http://localhost:8080|http://localhost:3000|g' "$launcher"
    ok "URL в kiosk-launcher.sh возвращён на http://localhost:3000"
  fi
  exit 0
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
  echo "  Двойное касание правого верхнего угла экрана"
  echo "  переключает между приложениями."
  echo ""
  echo "  Если HA показывает ошибку авторизации через прокси,"
  echo "  перезапустите контейнер: sudo docker restart homeassistant"
  echo ""
}

main "$@"
