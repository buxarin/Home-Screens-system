#!/bin/bash
# =============================================================================
#  Pi System Monitor — установщик виджета для Home Screens
#
#  Один запуск делает всё:
#    1. Ставит/обновляет расширенный System API (порт 4000)
#    2. Регистрирует плагин pi-system-monitor в Home Screens
#    3. Перезапускает сервисы
#
#  Запуск:   sudo ./install.sh [параметры]
#  Удаление: sudo ./install.sh --uninstall
#  Справка:  ./install.sh --help
#
#  Переменные окружения (необязательно):
#    REAL_USER=pi           HS_DIR=/home/pi/home-screens
#    SYSTEM_API_PORT=4000   VLESS_PORT=8443   SOCKS_PORT=1080
#    FAN_SERVICE=fan_hat    XRAY_SERVICE=xray
#    PCA9685_ADDR=0x40      PCA9685_BUS=1
# =============================================================================
set -o pipefail

PLUGIN_ID="pi-system-monitor"
PLUGIN_VERSION="1.1.0"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC}  $1"; }
ok(){   echo -e "${GREEN}[OK]${NC}    $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC}  $1"; }
err(){  echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step(){ echo -e "\n${CYAN}▸ $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── defaults (override via env) ───────────────────────────────────────────────
REAL_USER="${REAL_USER:-pi}"
SYSTEM_API_PORT="${SYSTEM_API_PORT:-4000}"
VLESS_PORT="${VLESS_PORT:-8443}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
FAN_SERVICE="${FAN_SERVICE:-fan_hat}"
XRAY_SERVICE="${XRAY_SERVICE:-xray}"
PCA9685_ADDR="${PCA9685_ADDR:-0x40}"
PCA9685_BUS="${PCA9685_BUS:-1}"

usage() {
  cat <<EOF
Использование: sudo ./install.sh [--uninstall | --help]

  (без флагов)   Установить / обновить плагин и System API
  --uninstall    Удалить плагин, восстановить прежний API (если есть бэкап)
  --help         Показать эту справку

Переменные окружения:
  REAL_USER=pi            — пользователь Home Screens (по умолчанию pi)
  HS_DIR=<путь>           — корневой каталог Home Screens
                            (по умолчанию /home/\$REAL_USER/home-screens)
  SYSTEM_API_PORT=4000    — порт System API
  VLESS_PORT=8443         — порт XRay VLESS
  SOCKS_PORT=1080         — порт XRay SOCKS5
  FAN_SERVICE=fan_hat     — имя systemd-службы вентилятора
  XRAY_SERVICE=xray       — имя systemd-службы XRay
  PCA9685_ADDR=0x40       — I2C-адрес PCA9685 (FanHat PWM)
  PCA9685_BUS=1           — I2C шина

Пример:
  sudo HS_DIR=/opt/home-screens VLESS_PORT=443 ./install.sh
EOF
  exit 0
}

check_root() { [ "$EUID" -eq 0 ] || err "Запустите через sudo."; }

resolve_paths() {
  id "$REAL_USER" &>/dev/null || err "Пользователь '$REAL_USER' не найден (укажите REAL_USER=...)."
  REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
  [ -n "$REAL_HOME" ] || REAL_HOME="/home/$REAL_USER"
  HS_DIR="${HS_DIR:-$REAL_HOME/home-screens}"
  API_PY="$REAL_HOME/system-api-server.py"
  PYTHON3_BIN="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"

  # Determine Home Screens data directory
  if   [ -d "$HS_DIR/data/plugins" ]; then HS_DATA="$HS_DIR/data"
  elif [ -d "$HS_DIR/data" ];         then HS_DATA="$HS_DIR/data"
  else
    warn "Каталог Home Screens '$HS_DIR' не найден."
    warn "Будет создан: $HS_DIR/data (убедитесь, что путь верный)."
    HS_DATA="$HS_DIR/data"
  fi

  PLUGIN_DIR="$HS_DATA/plugins/$PLUGIN_ID"
  INSTALLED_JSON="$HS_DATA/plugins/installed.json"
}

# ── uninstall ─────────────────────────────────────────────────────────────────
do_uninstall() {
  resolve_paths
  step "Удаление плагина $PLUGIN_ID"
  rm -rf "$PLUGIN_DIR"
  if [ -f "$INSTALLED_JSON" ]; then
    "$PYTHON3_BIN" - "$INSTALLED_JSON" "$PLUGIN_ID" <<'PY'
import json, sys
path, pid = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
    d["plugins"] = [x for x in d.get("plugins", []) if x.get("id") != pid]
    json.dump(d, open(path, "w"), indent=2)
    print("installed.json обновлён")
except Exception as e:
    print(f"Пропуск installed.json: {e}")
PY
    chown "$REAL_USER:$REAL_USER" "$INSTALLED_JSON" 2>/dev/null || true
  fi
  ok "Плагин удалён"

  step "Восстановление прежнего System API"
  if [ -f "$API_PY.bak" ]; then
    mv -f "$API_PY.bak" "$API_PY"
    chown "$REAL_USER:$REAL_USER" "$API_PY"
    systemctl restart system-api.service 2>/dev/null || true
    ok "Прежний system-api-server.py восстановлен из бэкапа"
  else
    warn "Бэкап не найден — system-api-server.py оставлен без изменений"
  fi

  systemctl restart home-screens.service 2>/dev/null || warn "Не удалось перезапустить home-screens.service"
  ok "Удаление завершено"
  exit 0
}

# ── install dependencies ──────────────────────────────────────────────────────
install_deps() {
  step "Проверка зависимостей"
  local need=()
  command -v ping >/dev/null || need+=(iputils-ping)
  command -v ss   >/dev/null || need+=(iproute2)
  command -v ip   >/dev/null || need+=(iproute2)
  "$PYTHON3_BIN" -c "import smbus" 2>/dev/null || need+=(python3-smbus)

  if [ ${#need[@]} -gt 0 ]; then
    info "Доустанавливаю: ${need[*]}"
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}" 2>/dev/null \
      || warn "apt не смог поставить часть пакетов (продолжаю)"
  fi

  # Give the pi user access to I2C (for FanHat PWM)
  if getent group i2c >/dev/null 2>&1; then
    usermod -aG i2c "$REAL_USER" 2>/dev/null && info "Пользователь $REAL_USER добавлен в группу i2c" || true
  fi
  ok "Зависимости готовы"
}

# ── install System API ────────────────────────────────────────────────────────
install_api() {
  step "Установка расширенного System API (порт $SYSTEM_API_PORT)"
  local src="$SCRIPT_DIR/server/system-api-server.py"
  [ -f "$src" ] || err "Не найден $src"

  # One-time backup
  if [ -f "$API_PY" ] && [ ! -f "$API_PY.bak" ]; then
    cp -f "$API_PY" "$API_PY.bak"
    info "Прежний API сохранён в $API_PY.bak"
  fi

  install -m 0755 -o "$REAL_USER" -g "$REAL_USER" "$src" "$API_PY"

  cat > /etc/systemd/system/system-api.service << EOF
[Unit]
Description=System API for Home Screens (Pi System Monitor)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$REAL_USER
SupplementaryGroups=i2c
WorkingDirectory=$REAL_HOME
Environment=SYSTEM_API_PORT=$SYSTEM_API_PORT
Environment=VLESS_PORT=$VLESS_PORT
Environment=SOCKS_PORT=$SOCKS_PORT
Environment=FAN_SERVICE=$FAN_SERVICE
Environment=XRAY_SERVICE=$XRAY_SERVICE
Environment=PCA9685_ADDR=$PCA9685_ADDR
Environment=PCA9685_BUS=$PCA9685_BUS
ExecStart=$PYTHON3_BIN $API_PY
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable system-api.service >/dev/null 2>&1 || true
  systemctl restart system-api.service
  sleep 2

  if curl -s --max-time 5 "http://localhost:$SYSTEM_API_PORT/?field=system.cpu" 2>/dev/null | grep -q '%'; then
    ok "System API отвечает на :$SYSTEM_API_PORT"
  else
    warn "System API пока не отвечает — проверьте: journalctl -u system-api -n 30"
  fi
}

# ── install plugin ────────────────────────────────────────────────────────────
install_plugin() {
  step "Установка плагина $PLUGIN_ID в Home Screens ($HS_DATA/plugins)"
  [ -f "$SCRIPT_DIR/manifest.json" ]   || err "manifest.json не найден рядом со скриптом"
  [ -f "$SCRIPT_DIR/dist/bundle.js" ]  || {
    warn "dist/bundle.js не найден."
    warn "Соберите плагин: cd pi-system-monitor && npm install && npm run build"
    warn "(или используйте предсобранный bundle.js из релиза)"
    err  "Установка прервана — bundle.js не найден"
  }

  mkdir -p "$PLUGIN_DIR/dist" "$PLUGIN_DIR/translations" "$HS_DATA/plugins"
  install -m 0644 "$SCRIPT_DIR/manifest.json"  "$PLUGIN_DIR/manifest.json"
  install -m 0644 "$SCRIPT_DIR/dist/bundle.js" "$PLUGIN_DIR/dist/bundle.js"
  if [ -d "$SCRIPT_DIR/translations" ]; then
    cp -f "$SCRIPT_DIR"/translations/*.json "$PLUGIN_DIR/translations/" 2>/dev/null || true
  fi

  # Register in installed.json
  "$PYTHON3_BIN" - "$INSTALLED_JSON" "$PLUGIN_ID" "$PLUGIN_VERSION" << 'PY'
import json, sys, os, datetime
path, pid, ver = sys.argv[1:4]
data = {"schemaVersion": 1, "plugins": []}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        pass
data.setdefault("schemaVersion", 1)
data.setdefault("plugins", [])
data["plugins"] = [x for x in data["plugins"] if x.get("id") != pid]
data["plugins"].append({
    "id": pid,
    "version": ver,
    "installedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "enabled": True,
    "moduleType": pid,
})
json.dump(data, open(path, "w"), indent=2)
print(f"  Зарегистрирован в {path}")
PY

  chown -R "$REAL_USER:$REAL_USER" "$HS_DATA/plugins" 2>/dev/null || true
  ok "Плагин установлен в $PLUGIN_DIR"

  # Version info
  if [ -f "$HS_DIR/package.json" ]; then
    HV="$("$PYTHON3_BIN" -c "import json; print(json.load(open('$HS_DIR/package.json')).get('version','?'))" 2>/dev/null)"
    info "Версия Home Screens: ${HV:-?} (плагин требует ≥ 0.20.0)"
  fi
}

# ── restart Home Screens ──────────────────────────────────────────────────────
restart_hs() {
  step "Перезапуск Home Screens"
  if systemctl list-units --all 2>/dev/null | grep -q "home-screens.service"; then
    systemctl restart home-screens.service \
      && ok "home-screens.service перезапущен" \
      || warn "Не удалось перезапустить home-screens.service"
  else
    warn "home-screens.service не найден — перезапустите дашборд вручную"
  fi
}

# ── summary ───────────────────────────────────────────────────────────────────
summary() {
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ГОТОВО — Pi System Monitor v${PLUGIN_VERSION} установлен${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${CYAN}▸ System API:${NC} http://localhost:${SYSTEM_API_PORT}/"
  echo "    Тест:       curl http://localhost:${SYSTEM_API_PORT}/ | python3 -m json.tool"
  echo "    Пинг:       curl 'http://localhost:${SYSTEM_API_PORT}/?ping=1.1.1.1'"
  echo "    Поле:       curl 'http://localhost:${SYSTEM_API_PORT}/?field=system.cpu'"
  echo ""
  echo -e "${CYAN}▸ Плагин в Home Screens:${NC}"
  echo "    Откройте редактор → палитра модулей → категория «System»"
  echo "    → «Pi System Monitor»."
  echo "    Добавьте столько модулей, сколько нужно (по одному на каждый"
  echo "    параметр: CPU, RAM, диск, темп, FanHat, адаптеры, VLESS, SOCKS5,""
  echo "    внешний IP, пинг) и расположите их по своему усмотрению."
  echo ""
  echo -e "${CYAN}▸ Метрики по одному плагину на карточку:${NC}"
  printf "    %-18s %s\n" "overview"    "Сводка: CPU/RAM/диск/темп + статус FanHat/VLESS/SOCKS5"
  printf "    %-18s %s\n" "cpu"         "Загрузка ЦП (bar/gauge/value) + sparkline"
  printf "    %-18s %s\n" "ram"         "ОЗУ: занято/всего + % + sparkline"
  printf "    %-18s %s\n" "disk"        "Диск: занято/всего + % + sparkline"
  printf "    %-18s %s\n" "temp"        "Температура ЦП + sparkline"
  printf "    %-18s %s\n" "fan"         "Статус FanHat + PWM%"
  printf "    %-18s %s\n" "adapters"    "Список адаптеров: имя, IP, UP/DOWN, MAC"
  printf "    %-18s %s\n" "external_ip" "Внешний IP"
  printf "    %-18s %s\n" "vless"       "VLESS: статус, порт, listening, клиенты"
  printf "    %-18s %s\n" "socks5"      "SOCKS5: статус, порт, listening, клиенты"
  printf "    %-18s %s\n" "ping"        "Пинг нескольких хостов (задаётся в настройках)"
  printf "    %-18s %s\n" "uptime"      "Время работы системы"
  echo ""
  echo -e "${CYAN}▸ Удаление:${NC}  sudo ./install.sh --uninstall"
  echo ""
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  case "${1:-}" in
    --help|-h)      usage ;;
    --uninstall|-u) check_root; do_uninstall ;;
    ""|--install)   ;;
    *)              err "Неизвестный флаг: $1  (используйте --help)" ;;
  esac

  check_root
  resolve_paths

  echo -e "${BLUE}Pi System Monitor — установка для пользователя '$REAL_USER'${NC}"
  echo -e "${BLUE}Home Screens: $HS_DIR${NC}"
  echo ""

  install_deps
  install_api
  install_plugin
  restart_hs
  summary
}

main "$@"
