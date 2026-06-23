# Pi System Monitor

Плагин для [Home Screens](https://homescreens.dev) — мониторинг Raspberry Pi 4 прямо на дашборде.

## Что отображает

Каждый экземпляр модуля показывает **один** параметр. Добавляйте столько карточек, сколько нужно.

| Метрика | Описание |
|---|---|
| `overview` | Сводка: CPU/RAM/диск/темп + статус FanHat, VLESS, SOCKS5 |
| `cpu` | Загрузка ЦП (%) + sparkline |
| `ram` | ОЗУ: занято/всего + % + sparkline |
| `disk` | Диск: занято/всего + % + sparkline |
| `temp` | Температура ЦП (°C) + sparkline |
| `fan` | Статус FanHat (online/offline) + PWM% |
| `adapters` | Сетевые адаптеры: имя, IPv4, UP/DOWN, MAC |
| `external_ip` | Внешний IP-адрес |
| `vless` | VLESS: название, статус, порт, listening, активные клиенты |
| `socks5` | SOCKS5: то же самое |
| `ping` | Пинг нескольких хостов (список в настройках виджета) |
| `uptime` | Время работы системы |

## Компоненты

```
pi-system-monitor/
├── dist/bundle.js          ← предсобранный плагин (IIFE, без зависимостей)
├── server/
│   └── system-api-server.py  ← HTTP-сервер на порту 4000 (stdlib Python 3)
├── src/index.tsx           ← исходный код компонента (React + TypeScript)
├── translations/           ← строки en-US / ru-RU
├── manifest.json           ← метаданные плагина
├── install.sh              ← установщик «одним запуском»
├── package.json
├── tsconfig.json
└── vite.config.ts
```

## Быстрый старт

```bash
sudo ./install.sh
```

Скрипт:
1. Устанавливает расширенный `system-api-server.py` в `~pi/`
2. Настраивает systemd-службу `system-api.service` (порт 4000)
3. Копирует плагин в `~/home-screens/data/plugins/pi-system-monitor/`
4. Регистрирует плагин в `installed.json`
5. Перезапускает `home-screens.service`

После этого в редакторе Home Screens появится раздел **«System»** → **«Pi System Monitor»**.

## Переменные установки

```bash
sudo REAL_USER=pi VLESS_PORT=443 HS_DIR=/opt/home-screens ./install.sh
```

| Переменная | По умолчанию | Описание |
|---|---|---|
| `REAL_USER` | `pi` | Пользователь Home Screens |
| `HS_DIR` | `~/home-screens` | Корень Home Screens |
| `SYSTEM_API_PORT` | `4000` | Порт System API |
| `VLESS_PORT` | `8443` | Порт XRay VLESS |
| `SOCKS_PORT` | `1080` | Порт XRay SOCKS5 |
| `FAN_SERVICE` | `fan_hat` | Имя systemd-службы FanHat |
| `XRAY_SERVICE` | `xray` | Имя systemd-службы XRay |
| `PCA9685_ADDR` | `0x40` | I2C-адрес PCA9685 (FanHat PWM) |
| `PCA9685_BUS` | `1` | I2C шина |

## Удаление

```bash
sudo ./install.sh --uninstall
```

## Сборка из исходников

```bash
npm install
npm run build      # → dist/bundle.js
```

Требования: Node.js 18+.

## API-эндпоинты

| URL | Формат | Описание |
|---|---|---|
| `GET /` | JSON | Полный снимок системы |
| `GET /?field=system.cpu` | text | Одно поле (совместимость) |
| `GET /?ping=1.1.1.1` | JSON | `{"host","ok","ms"}` |

Доступные поля: `system.cpu`, `system.ram_pct`, `system.ram_used`, `system.ram_total`, `system.ram_free`, `system.disk_pct`, `system.disk_used`, `system.disk_total`, `system.temp`, `system.uptime`, `fan.status`, `fan.pwm`, `network.external_ip`, `network.wifi_ssid`, `vless.status`, `vless.client_count`, `socks5.status`, `socks5.client_count`.

## Цветовая логика

| Уровень | CPU/RAM/Disk | Температура | Прокси |
|---|---|---|---|
| 🟢 Зелёный | < 80 % | < 65 °C | Online + есть клиенты |
| 🟡 Жёлтый | 80–94 % | 65–79 °C | Online, нет клиентов / idle |
| 🔴 Красный | ≥ 95 % | ≥ 80 °C | Offline / не слушает порт |

Пороги можно переопределить в настройках каждого модуля (`warnThreshold`, `critThreshold`).
