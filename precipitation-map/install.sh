#!/bin/bash
# =============================================================================
#  Precipitation Map — установщик плагина для Home Screens
#  Запуск:   sudo ./install.sh
#  Удаление: sudo ./install.sh --uninstall
# =============================================================================
set -o pipefail

PLUGIN_ID="precipitation-map"
PLUGIN_VERSION="1.0.0"

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

resolve_paths() {
  id "$REAL_USER" &>/dev/null || err "Пользователь '$REAL_USER' не найден."
  REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

  if [ -z "${HS_DIR:-}" ]; then
    for candidate in \
        "/opt/home-screens/current" \
        "$REAL_HOME/home-screens" \
        "/opt/home-screens" \
        "/home/pi/home-screens"; do
      if [ -d "$candidate/data/plugins" ] || [ -f "$candidate/package.json" ]; then
        HS_DIR="$candidate"; info "Home Screens найден: $HS_DIR"; break
      fi
    done
    HS_DIR="${HS_DIR:-$REAL_HOME/home-screens}"
  fi

  if   [ -d "$HS_DIR/data/plugins" ]; then HS_DATA="$HS_DIR/data"
  elif [ -d "$HS_DIR/data" ];         then HS_DATA="$HS_DIR/data"
  else HS_DATA="$HS_DIR/data"; fi

  PLUGIN_DIR="$HS_DATA/plugins/$PLUGIN_ID"
  INSTALLED_JSON="$HS_DATA/plugins/installed.json"
}

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
    print(f"Пропуск: {e}")
PY
    chown "$REAL_USER:$REAL_USER" "$INSTALLED_JSON" 2>/dev/null || true
  fi
  systemctl restart home-screens.service 2>/dev/null || true
  ok "Плагин удалён"
  exit 0
}

install_plugin() {
  step "Установка плагина $PLUGIN_ID"
  [ -f "$SCRIPT_DIR/manifest.json" ]  || err "manifest.json не найден"
  [ -f "$SCRIPT_DIR/dist/bundle.js" ] || err "dist/bundle.js не найден — соберите: npm install && npm run build"

  mkdir -p "$PLUGIN_DIR/dist"
  install -m 0644 "$SCRIPT_DIR/manifest.json"  "$PLUGIN_DIR/manifest.json"
  install -m 0644 "$SCRIPT_DIR/dist/bundle.js" "$PLUGIN_DIR/dist/bundle.js"

  "$PYTHON3_BIN" - "$INSTALLED_JSON" "$PLUGIN_ID" "$PLUGIN_VERSION" <<'PY'
import json, sys, os, datetime
path, pid, ver = sys.argv[1:4]
data = {"schemaVersion": 1, "plugins": []}
if os.path.exists(path):
    try: data = json.load(open(path))
    except: pass
data.setdefault("schemaVersion", 1)
data.setdefault("plugins", [])
data["plugins"] = [x for x in data["plugins"] if x.get("id") != pid]
data["plugins"].append({
    "id": pid, "version": ver,
    "installedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "enabled": True, "moduleType": pid,
})
json.dump(data, open(path, "w"), indent=2)
print(f"  Зарегистрирован в {path}")
PY

  chown -R "$REAL_USER:$REAL_USER" "$HS_DATA/plugins" 2>/dev/null || true
  ok "Плагин установлен в $PLUGIN_DIR"
}

restart_hs() {
  step "Перезапуск Home Screens"
  systemctl restart home-screens.service \
    && ok "home-screens.service перезапущен" \
    || warn "Не удалось перезапустить — перезапустите вручную"
}

main() {
  case "${1:-}" in
    --uninstall|-u) check_root; resolve_paths; do_uninstall ;;
    --help|-h)
      echo "Использование: sudo ./install.sh [--uninstall]"
      echo "Переменные: REAL_USER=pi  HS_DIR=/opt/home-screens/current"
      exit 0 ;;
    ""|--install) ;;
    *) err "Неизвестный флаг: $1" ;;
  esac

  check_root
  resolve_paths
  echo -e "${BLUE}Precipitation Map Plugin — установка (пользователь: $REAL_USER, HS: $HS_DIR)${NC}"
  install_plugin
  restart_hs
  echo ""
  echo -e "${GREEN}═══════════════════════════════════════${NC}"
  echo -e "${GREEN}  Precipitation Map v${PLUGIN_VERSION} установлен${NC}"
  echo -e "${GREEN}═══════════════════════════════════════${NC}"
  echo "  Откройте редактор → палитра → «Weather & Environment» → «Precipitation Map»"
  echo "  Настройте центр карты (широта/долгота) и зум."
  echo "  Данные радара обновляются каждые 10 мин (RainViewer)."
  echo ""
}

main "$@"
