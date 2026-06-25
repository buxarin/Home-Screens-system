# Home Screens System

Плагины и инфраструктура для [Home Screens](https://homescreens.dev) на Raspberry Pi.

## Компоненты

| Компонент | Описание |
|-----------|----------|
| `uv-index` | Виджет UV-индекса (Open-Meteo API, без ключа) |
| `precipitation-map` | Анимированная карта осадков (RainViewer, без ключа) |
| `pi-system-monitor` | Системный монитор Pi (CPU, RAM, диск, темп, FanHat, Xray) |
| `app-switcher` | Переключение Home Screens ↔ Home Assistant по тапу на экран |

---

## Полное восстановление системы

### Шаг 0 — Первичная настройка Pi (вручную, перед скриптами)

Эти шаги выполняются один раз при первичной установке и **не автоматизированы**:

#### 0.1 Установка Home Screens
```bash
# Официальный установщик Home Screens (уточнить команду):
# curl -fsSL https://homescreens.dev/install.sh | bash
# После установки Home Screens работает как:
#   systemd-сервис: home-screens.service
#   путь:           /opt/home-screens/current/
#   порт:           3000 (настраивается в data/port.conf)
```

#### 0.2 Поворот экрана
Настраивается через интерфейс Home Screens (Setup → Display → Rotation).  
Home Screens сам записывает `DISPLAY_TRANSFORM` в `/opt/home-screens/current/data/kiosk.conf`.

#### 0.3 Установка Xray (VLESS + SOCKS5)
```bash
# Официальный установщик Xray:
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

# Конфиг: /usr/local/etc/xray/config.json
# Сервис:  xray.service
# Порты:   8443 (VLESS), 1080 (SOCKS5)
```

#### 0.4 Установка FanHat
```bash
# FanHat управляется через PCA9685 (I2C 0x40, bus 1)
# Сервис: fan_hat.service
# Включить I2C:
sudo raspi-config nonint do_i2c 0
```

---

### Шаг 1 — Клонировать репозиторий

```bash
cd ~
git clone https://github.com/buxarin/Home-Screens-system.git
cd Home-Screens-system
git checkout claude/bold-dirac-5gku2r
```

### Шаг 2 — Собрать плагины (требуется Node.js 18+)

```bash
cd uv-index        && npm install && npm run build && cd ..
cd precipitation-map && npm install && npm run build && cd ..
cd pi-system-monitor && npm install && npm run build && cd ..
```

### Шаг 3 — Запустить полный установщик

```bash
sudo bash setup_all.sh
```

Установщик делает:
1. ✅ Pi System Monitor (system-api на порту 4000)
2. ✅ UV Index плагин
3. ✅ Precipitation Map плагин
4. ✅ Docker + Home Assistant (порт 8123)
5. ✅ App Switcher (nginx proxy 8080/8081 + kiosk-switcher daemon)
6. ✅ Патч Chromium: `--remote-allow-origins=*`

### Шаг 4 — Перезагрузить

```bash
sudo reboot
```

### Шаг 5 — Онбординг Home Assistant (один раз)

С телефона или ноутбука в той же сети:
```
http://<IP малинки>:8081
```
Создать аккаунт администратора. После этого кiosk автоматически заходит в HA без клавиатуры.

---

## Переменные для setup_all.sh

```bash
REAL_USER=pi              # пользователь Pi (по умолчанию pi)
TZ=Asia/Nicosia           # часовой пояс Home Assistant
HA_CONFIG_DIR=/opt/homeassistant  # папка конфигов HA
```

Пример с переопределением:
```bash
sudo TZ=Europe/Moscow bash setup_all.sh
```

---

## Отдельные установщики

```bash
# Pi System Monitor (включает system-api-server.py)
cd pi-system-monitor
sudo ./install.sh

# UV Index
cd uv-index && npm run build
sudo ./install.sh

# Precipitation Map
cd precipitation-map && npm run build
sudo ./install.sh

# App Switcher (nginx + kiosk-switcher daemon + HA trusted_networks)
cd app-switcher
sudo ./install.sh
```

---

## Адреса после установки

| URL | Что открывает |
|-----|---------------|
| `http://<IP>:8080/display` | Home Screens (через nginx — для kiosk) |
| `http://<IP>:8081` | Home Assistant (через nginx) |
| `http://<IP>:3000` | Home Screens (напрямую) |
| `http://<IP>:8123` | Home Assistant (напрямую) |
| `http://<IP>:4000` | System API (Pi System Monitor) |

**Переключение в kiosk-режиме:** тап в правый верхний угол экрана.

---

## Диагностика

```bash
# Логи переключателя
sudo journalctl -u kiosk-switcher -f

# Логи System API
sudo journalctl -u system-api -f

# Home Assistant
sudo docker ps
sudo docker logs homeassistant --tail 50

# nginx
sudo nginx -t
sudo systemctl status nginx

# Проверить флаги Chromium (должен быть --remote-allow-origins=*)
grep remote-allow /opt/home-screens/current/scripts/kiosk-launcher.sh

# Тест System API
curl http://localhost:4000/ | python3 -m json.tool
```

---

## Конфигурация сервисов

| Сервис | Описание | Порт |
|--------|----------|------|
| `home-screens.service` | Home Screens | 3000 |
| `system-api.service` | Pi System Monitor API | 4000 |
| `nginx.service` | Reverse proxy (switcher) | 8080, 8081 |
| `kiosk-switcher.service` | Демон переключения по тапу | — |
| `homeassistant` (Docker) | Home Assistant | 8123 |
| `xray.service` | VLESS прокси | 8443 |
| `xray.service` | SOCKS5 прокси | 1080 |
| `fan_hat.service` | FanHat (PWM через I2C) | — |
