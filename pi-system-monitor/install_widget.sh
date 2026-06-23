#!/bin/bash
# =============================================================================
#  Pi System Monitor — установщик виджета Home Screens + расширенного System API
#
#  Запуск:   sudo ./install_widget.sh
#  Удаление: sudo ./install_widget.sh --uninstall
#  Справка:  ./install_widget.sh --help
#
#  Что делает за один запуск:
#    1. Ставит расширенный System API (порт 4000): CPU/RAM/диск/темп, статус и
#       PWM% FanHat, все сетевые адаптеры, раздельные VLESS/SOCKS5 + клиенты,
#       endpoint пинга ?ping=host.
#    2. Устанавливает плагин-модуль "Pi System Monitor" в Home Screens.
#    3. Перезапускает службы. Виджет появляется в палитре редактора —
#       раскладку вы делаете сами.
# =============================================================================
set -o pipefail
PLUGIN_ID="pi-system-monitor"
PLUGIN_VERSION="1.0.0"
MODULE_TYPE="pi-system-monitor"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC}  $1"; }
ok(){   echo -e "${GREEN}[OK]${NC}    $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC}  $1"; }
err(){  echo -e "${RED}[ERROR]${NC} $1"; }
step(){ echo -e "\n${CYAN}▸ $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- параметры (можно переопределить через переменные окружения) ------------
REAL_USER="${REAL_USER:-pi}"
SYSTEM_API_PORT="${SYSTEM_API_PORT:-4000}"
VLESS_PORT="${VLESS_PORT:-8443}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
FAN_SERVICE="${FAN_SERVICE:-fan_hat}"
XRAY_SERVICE="${XRAY_SERVICE:-xray}"
PCA9685_ADDR="${PCA9685_ADDR:-0x40}"
PCA9685_BUS="${PCA9685_BUS:-1}"

usage(){
  echo "Использование: sudo ./install_widget.sh [--uninstall]"
  echo "  (без флагов)  установить/обновить виджет и API"
  echo "  --uninstall   удалить виджет, вернуть прежний API (если был бэкап)"
  echo ""
  echo "Переменные окружения (необязательно):"
  echo "  REAL_USER=pi  HS_DIR=/home/pi/home-screens  SYSTEM_API_PORT=4000"
  echo "  VLESS_PORT=8443  SOCKS_PORT=1080  FAN_SERVICE=fan_hat  XRAY_SERVICE=xray"
  echo "  PCA9685_ADDR=0x40  PCA9685_BUS=1"
  exit 0
}

check_root(){ [ "$EUID" -eq 0 ] || { err "Запустите через sudo."; exit 1; }; }

resolve_paths(){
  id "$REAL_USER" &>/dev/null || { err "Пользователь '$REAL_USER' не найден (укажите REAL_USER=...)."; exit 1; }
  REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
  [ -n "$REAL_HOME" ] || REAL_HOME="/home/$REAL_USER"
  HS_DIR="${HS_DIR:-$REAL_HOME/home-screens}"
  API_PY="$REAL_HOME/system-api-server.py"
  PYTHON3_BIN="$(command -v python3 || echo /usr/bin/python3)"

  # каталог data Home Screens
  if   [ -d "$HS_DIR/data" ]; then HS_DATA="$HS_DIR/data"
  elif [ -d "$HS_DIR" ];      then HS_DATA="$HS_DIR/data"
  else
    warn "Каталог Home Screens '$HS_DIR' не найден."
    warn "Укажите путь: sudo HS_DIR=/путь/к/home-screens ./install_widget.sh"
    HS_DATA="$HS_DIR/data"
  fi
  PLUGIN_DIR="$HS_DATA/plugins/$PLUGIN_ID"
  INSTALLED_JSON="$HS_DATA/plugins/installed.json"
}

# =============================================================================
# УДАЛЕНИЕ
# =============================================================================
do_uninstall(){
  step "Удаление плагина $PLUGIN_ID"
  rm -rf "$PLUGIN_DIR"
  if [ -f "$INSTALLED_JSON" ]; then
    "$PYTHON3_BIN" - "$INSTALLED_JSON" "$PLUGIN_ID" <<'PY'
import json,sys
p,pid=sys.argv[1],sys.argv[2]
try:
    d=json.load(open(p))
    d["plugins"]=[x for x in d.get("plugins",[]) if x.get("id")!=pid]
    json.dump(d,open(p,"w"),indent=2)
    print("installed.json updated")
except Exception as e:
    print("skip installed.json:",e)
PY
    chown "$REAL_USER:$REAL_USER" "$INSTALLED_JSON" 2>/dev/null || true
  fi
  ok "Плагин удалён"

  step "Восстановление прежнего System API"
  if [ -f "$API_PY.bak" ]; then
    mv -f "$API_PY.bak" "$API_PY"
    chown "$REAL_USER:$REAL_USER" "$API_PY"
    systemctl restart system-api.service 2>/dev/null || true
    ok "Старый system-api-server.py восстановлен из бэкапа"
  else
    warn "Бэкап не найден — system-api оставлен без изменений"
  fi

  systemctl restart home-screens.service 2>/dev/null || warn "Не удалось перезапустить home-screens.service"
  ok "Удаление завершено"
  exit 0
}

# =============================================================================
# УСТАНОВКА
# =============================================================================
install_deps(){
  step "Проверка зависимостей"
  local need=()
  command -v ping    >/dev/null || need+=(iputils-ping)
  command -v ss      >/dev/null || need+=(iproute2)
  command -v ip      >/dev/null || need+=(iproute2)
  "$PYTHON3_BIN" -c "import smbus" 2>/dev/null || need+=(python3-smbus)
  if [ ${#need[@]} -gt 0 ]; then
    info "Доустанавливаю: ${need[*]}"
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}" 2>/dev/null || warn "apt не смог поставить часть пакетов (продолжаю)"
  fi
  # доступ к I2C для чтения PWM вентилятора
  if getent group i2c >/dev/null; then
    usermod -aG i2c "$REAL_USER" 2>/dev/null && info "Пользователь $REAL_USER добавлен в группу i2c" || true
  fi
  ok "Зависимости готовы"
}

install_api(){
  step "Установка расширенного System API (порт $SYSTEM_API_PORT)"
  local src="$SCRIPT_DIR/server/system-api-server.py"
  [ -f "$src" ] || { err "Не найден $src"; exit 1; }

  # бэкап прежней версии (один раз)
  if [ -f "$API_PY" ] && [ ! -f "$API_PY.bak" ]; then
    cp -f "$API_PY" "$API_PY.bak"
    info "Прежний API сохранён в $API_PY.bak"
  fi
  install -m 0755 -o "$REAL_USER" -g "$REAL_USER" "$src" "$API_PY"

  cat > /etc/systemd/system/system-api.service <<EOF
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
  if curl -s --max-time 4 "http://localhost:$SYSTEM_API_PORT/?field=system.cpu" | grep -q '%'; then
    ok "System API отвечает на :$SYSTEM_API_PORT"
  else
    warn "System API пока не отвечает — проверьте: journalctl -u system-api -n 30"
  fi
}

install_plugin(){
  step "Установка плагина $PLUGIN_ID в Home Screens"
  [ -f "$SCRIPT_DIR/manifest.json" ]   || { err "manifest.json не найден рядом со скриптом"; exit 1; }
  [ -f "$SCRIPT_DIR/dist/bundle.js" ]  || { err "dist/bundle.js не найден (соберите: npm run build)"; exit 1; }

  if [ ! -d "$HS_DATA" ]; then
    warn "Каталог $HS_DATA не существует — создаю (проверьте, что путь верный)."
  fi
  mkdir -p "$PLUGIN_DIR/dist" "$PLUGIN_DIR/translations" "$HS_DATA/plugins"
  install -m 0644 "$SCRIPT_DIR/manifest.json"  "$PLUGIN_DIR/manifest.json"
  install -m 0644 "$SCRIPT_DIR/dist/bundle.js" "$PLUGIN_DIR/dist/bundle.js"
  if [ -d "$SCRIPT_DIR/translations" ]; then
    cp -f "$SCRIPT_DIR"/translations/*.json "$PLUGIN_DIR/translations/" 2>/dev/null || true
  fi

  # регистрация в installed.json (с сохранением остальных плагинов)
  "$PYTHON3_BIN" - "$INSTALLED_JSON" "$PLUGIN_ID" "$PLUGIN_VERSION" "$MODULE_TYPE" <<'PY'
import json,sys,os,datetime
path,pid,ver,mt=sys.argv[1:5]
data={"schemaVersion":1,"plugins":[]}
if os.path.exists(path):
    try: data=json.load(open(path))
    except Exception: pass
data.setdefault("schemaVersion",1); data.setdefault("plugins",[])
data["plugins"]=[x for x in data["plugins"] if x.get("id")!=pid]
data["plugins"].append({
    "id":pid,"version":ver,
    "installedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "enabled":True,"moduleType":mt})
json.dump(data,open(path,"w"),indent=2)
print("registered in installed.json")
PY

  chown -R "$REAL_USER:$REAL_USER" "$HS_DATA/plugins" 2>/dev/null || true
  ok "Файлы плагина установлены в $PLUGIN_DIR"

  # предупреждение о версии хоста
  if [ -f "$HS_DIR/package.json" ]; then
    HV="$("$PYTHON3_BIN" -c "import json;print(json.load(open('$HS_DIR/package.json')).get('version','0'))" 2>/dev/null)"
    [ -n "$HV" ] && info "Версия Home Screens: $HV (плагин требует ≥ 0.20.0)"
  fi
}

restart_hs(){
  step "Перезапуск Home Screens"
  if systemctl list-units --all 2>/dev/null | grep -q home-screens.service; then
    systemctl restart home-screens.service && ok "home-screens.service перезапущен" \
      || warn "Не удалось перезапустить home-screens.service"
  else
    warn "home-screens.service не найден — перезапустите дашборд вручную"
  fi
}

summary(){
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ГОТОВО — Pi System Monitor установлен${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${CYAN}▸ System API:${NC} http://localhost:$SYSTEM_API_PORT/"
  echo "    проверка:  curl http://localhost:$SYSTEM_API_PORT/ | python3 -m json.tool"
  echo "    пинг:      curl 'http://localhost:$SYSTEM_API_PORT/?ping=1.1.1.1'"
  echo ""
  echo -e "${CYAN}▸ Виджет в редакторе:${NC}"
  echo "    Откройте редактор Home Screens → палитра модулей → категория 'System'"
  echo "    → 'Pi System Monitor'. Поставьте нужное число модулей и в каждом"
  echo "    выберите параметр (CPU/RAM/диск/темп/FanHat/адаптеры/внешний IP/"
  echo "    VLESS/SOCKS5/пинг), тип отображения, значок-эмодзи, шрифт и размер."
  echo ""
  echo -e "${CYAN}▸ Удаление:${NC} sudo ./install_widget.sh --uninstall"
  echo ""
}

main(){
  case "${1:-}" in
    --help|-h) usage ;;
  esac
  check_root
  resolve_paths
  if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    do_uninstall
  fi
  echo -e "${BLUE}Установка Pi System Monitor для пользователя '$REAL_USER'${NC}"
  echo -e "${BLUE}Home Screens: $HS_DIR${NC}"
  install_deps
  install_api
  install_plugin
  restart_hs
  summary
}
main "$@"
