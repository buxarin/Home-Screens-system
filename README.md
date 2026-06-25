# Home Screens System

Плагины и инфраструктура для [Home Screens](https://github.com/home-screens/home-screens) на Raspberry Pi.

## Компоненты

| Компонент | Описание |
|-----------|----------|
| `uv-index` | Виджет UV-индекса (Open-Meteo API) |
| `precipitation-map` | Анимированная карта осадков (RainViewer) |
| `pi-system-monitor` | Системный монитор Pi (CPU, RAM, температура) |
| `app-switcher` | Переключение между Home Screens и Home Assistant по тапу |

---

## Восстановление / первая установка

### Требования

- Raspberry Pi с установленным **Home Screens** (должен быть запущен и доступен)
- Доступ к Pi по SSH
- Node.js (обычно уже есть вместе с Home Screens)

### Шаги

```bash
# 1. Клонировать репозиторий
cd ~
git clone https://github.com/buxarin/Home-Screens-system.git
cd Home-Screens-system
git checkout claude/bold-dirac-5gku2r

# 2. Собрать плагины (нужен Node.js)
cd uv-index && npm install && npm run build && cd ..
cd precipitation-map && npm install && npm run build && cd ..

# 3. Запустить полный установщик
sudo bash setup_all.sh

# 4. Перезагрузить
sudo reboot
```

### После ребута — онбординг Home Assistant (один раз)

Откройте в браузере на телефоне или ноутбуке:
```
http://<IP малинки>:8081
```
Создайте аккаунт администратора. После этого кiosk будет заходить в HA автоматически без клавиатуры.

---

## Отдельные установщики

```bash
# Только плагин UV Index
cd uv-index && npm install && npm run build
sudo ./install.sh

# Только карта осадков
cd precipitation-map && npm install && npm run build
sudo ./install.sh

# Только системный монитор
cd pi-system-monitor
sudo ./install.sh

# Только переключатель HS ↔ HA
cd app-switcher
sudo ./install.sh
```

---

## После установки

| URL | Что открывает |
|-----|---------------|
| `http://<IP>:8080` | Home Screens (через nginx proxy) |
| `http://<IP>:8081` | Home Assistant (через nginx proxy) |
| `http://<IP>:3000` | Home Screens (напрямую) |
| `http://<IP>:8123` | Home Assistant (напрямую) |

**Переключение в kiosk-режиме:** тап в правый верхний угол экрана.

---

## Диагностика

```bash
# Логи переключателя приложений
sudo journalctl -u kiosk-switcher -f

# Статус Home Assistant
sudo docker ps
sudo docker logs homeassistant --tail 50

# Статус nginx
sudo nginx -t
sudo systemctl status nginx

# Проверить флаги Chromium (должен быть --remote-allow-origins=*)
grep remote-allow /opt/home-screens/current/scripts/kiosk-launcher.sh
```

---

## Переменные окружения для setup_all.sh

```bash
REAL_USER=pi          # пользователь Pi (по умолчанию pi)
TZ=Asia/Nicosia       # часовой пояс для Home Assistant
HA_CONFIG_DIR=/opt/homeassistant  # папка конфигов HA
```
