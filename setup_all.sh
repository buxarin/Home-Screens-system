#!/bin/bash
# =============================================================================
#  Home Screens System — полное восстановление на новой малинке
#
#  Запуск:  sudo bash setup_all.sh
#
#  Порядок:
#   0. Предварительные требования (Home Screens уже должен быть установлен)
#   1. Плагин Pi System Monitor (системный монитор)
#   2. Плагин UV Index (индекс ультрафиолета)
#   3. Плагин Precipitation Map (карта осадков)
#   4. Docker + Home Assistant
#   5. App Switcher (переключение HS ↔ HA по тапу)
#
#  После завершения — один ребут: sudo reboot
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC}  $1"; }
ok(){   echo -e "${GREEN}[OK]${NC}    $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC}  $1"; }
err(){  echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step(){ echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; \
        echo -e "${CYAN}  $1${NC}"; \
        echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${REAL_USER:-pi}"
TZ="${TZ:-Asia/Nicosia}"
HA_CONFIG_DIR="${HA_CONFIG_DIR:-/opt/homeassistant}"

[ "$EUID" -eq 0 ] || err "Запустите через sudo: sudo bash setup_all.sh"

# ── 0. Проверки ───────────────────────────────────────────────────────────────
step "0. Проверка Home Screens"

HS_RUNNING=false
for candidate in \
    "/opt/home-screens/current" \
    "/home/${REAL_USER}/home-screens" \
    "/opt/home-screens" \
    "/home/pi/home-screens"; do
  if [ -d "$candidate/data/plugins" ] || [ -f "$candidate/package.json" ]; then
    HS_DIR="$candidate"
    HS_RUNNING=true
    ok "Home Screens найден: $HS_DIR"
    break
  fi
done

if ! $HS_RUNNING; then
  warn "Home Screens не найден в стандартных путях."
  warn "Установите Home Screens сначала, затем повторите запуск этого скрипта."
  warn "После установки Home Screens запустите: sudo bash $0"
  exit 1
fi

# ── 1. Pi System Monitor ──────────────────────────────────────────────────────
step "1. Pi System Monitor"
if [ -f "$SCRIPT_DIR/pi-system-monitor/install.sh" ]; then
  bash "$SCRIPT_DIR/pi-system-monitor/install.sh" || warn "Pi System Monitor: ошибка установки"
else
  warn "pi-system-monitor/install.sh не найден — пропуск"
fi

# ── 2. UV Index ───────────────────────────────────────────────────────────────
step "2. UV Index"
UV_DIR="$SCRIPT_DIR/uv-index"
if [ -f "$UV_DIR/install.sh" ]; then
  if [ ! -f "$UV_DIR/dist/bundle.js" ]; then
    info "Сборка uv-index..."
    (cd "$UV_DIR" && npm install && npm run build) || err "uv-index: сборка не удалась"
  fi
  bash "$UV_DIR/install.sh" || warn "UV Index: ошибка установки"
else
  warn "uv-index/install.sh не найден — пропуск"
fi

# ── 3. Precipitation Map ──────────────────────────────────────────────────────
step "3. Precipitation Map"
PM_DIR="$SCRIPT_DIR/precipitation-map"
if [ -f "$PM_DIR/install.sh" ]; then
  if [ ! -f "$PM_DIR/dist/bundle.js" ]; then
    info "Сборка precipitation-map..."
    (cd "$PM_DIR" && npm install && npm run build) || err "precipitation-map: сборка не удалась"
  fi
  bash "$PM_DIR/install.sh" || warn "Precipitation Map: ошибка установки"
else
  warn "precipitation-map/install.sh не найден — пропуск"
fi

# ── 4. Docker + Home Assistant ────────────────────────────────────────────────
step "4. Docker + Home Assistant"

if ! command -v docker &>/dev/null; then
  info "Установка Docker..."
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker "$REAL_USER"
  ok "Docker установлен"
else
  ok "Docker уже установлен: $(docker --version)"
fi

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; then
  info "Контейнер homeassistant уже существует"
  docker start homeassistant 2>/dev/null || true
  ok "homeassistant запущен"
else
  info "Запуск Home Assistant контейнера..."
  mkdir -p "$HA_CONFIG_DIR"
  docker run -d \
    --name homeassistant \
    --privileged \
    --restart=unless-stopped \
    -e TZ="$TZ" \
    -v "$HA_CONFIG_DIR":/config \
    --network=host \
    ghcr.io/home-assistant/home-assistant:stable
  ok "Home Assistant контейнер запущен (порт 8123)"
fi

# Проверяем доступность HA (ждём до 60 сек)
info "Ожидание готовности Home Assistant..."
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8123 2>/dev/null || echo 0)
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    ok "Home Assistant доступен (HTTP $code)"
    break
  fi
  sleep 2
done

# ── 5. App Switcher ───────────────────────────────────────────────────────────
step "5. App Switcher (Home Screens ↔ Home Assistant)"
AS_DIR="$SCRIPT_DIR/app-switcher"
if [ -f "$AS_DIR/install.sh" ]; then
  bash "$AS_DIR/install.sh" || warn "App Switcher: ошибка установки"
else
  warn "app-switcher/install.sh не найден — пропуск"
fi

# ── Финальный патч kiosk-launcher: --remote-allow-origins=* ──────────────────
# (на случай если install.sh пропустил обновление из-за grep-проверки)
LAUNCHER=""
for f in \
    /opt/home-screens/current/scripts/kiosk-launcher.sh \
    "/home/${REAL_USER}/home-screens/scripts/kiosk-launcher.sh" \
    /opt/home-screens/scripts/kiosk-launcher.sh; do
  [ -f "$f" ] && { LAUNCHER="$f"; break; }
done
if [ -n "$LAUNCHER" ]; then
  if grep -q "remote-allow-origins=http" "$LAUNCHER"; then
    sed -i 's|--remote-allow-origins=http[^ \\]*|--remote-allow-origins=*|g' "$LAUNCHER"
    ok "kiosk-launcher.sh: --remote-allow-origins обновлён до *"
  elif ! grep -q "remote-allow-origins" "$LAUNCHER"; then
    sed -i 's/--remote-debugging-port=9222/--remote-debugging-port=9222 \\\n  --remote-allow-origins=*/' "$LAUNCHER"
    ok "kiosk-launcher.sh: --remote-allow-origins=* добавлен"
  else
    ok "kiosk-launcher.sh: --remote-allow-origins=* уже установлен"
  fi
fi

# ── Итог ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Установка завершена успешно!                 ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Home Screens   → http://localhost:8080/display      ║${NC}"
echo -e "${GREEN}║  Home Assistant → http://localhost:8081              ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Для применения всех изменений:                      ║${NC}"
echo -e "${GREEN}║    sudo reboot                                       ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  После ребута — онбординг HA (один раз):             ║${NC}"
echo -e "${GREEN}║    Откройте с телефона/ноутбука:                     ║${NC}"
echo -e "${GREEN}║    http://$(hostname -I | awk '{print $1}'):8081                  ║${NC}"
echo -e "${GREEN}║  Создайте аккаунт, затем в киоске авто-логин         ║${NC}"
echo -e "${GREEN}║  будет работать без клавиатуры.                      ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Переключение приложений:                            ║${NC}"
echo -e "${GREEN}║    Тап в правый верхний угол экрана                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Лог переключателя: ${CYAN}sudo journalctl -u kiosk-switcher -f${NC}"
echo ""
