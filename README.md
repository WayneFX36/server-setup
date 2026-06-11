<div align="center">

<img src="https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=700&size=28&pause=1000&color=00D9FF&center=true&vCenter=true&width=600&lines=SERVER+SETUP+v1.3;Ubuntu+%E2%80%A2+Rocky+%E2%80%A2+AlmaLinux+%E2%80%A2+RHEL" alt="Typing SVG" />

<br/>

**Swap · DNS · Docker · Firewall · SSH · Fail2ban · Self SNI · Remnanode**

<br/>

[![Bash](https://img.shields.io/badge/bash-5.0+-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![OS](https://img.shields.io/badge/OS-Ubuntu%20%7C%20Rocky%20%7C%20RHEL-orange?style=flat-square&logo=linux&logoColor=white)](https://github.com)
[![Version](https://img.shields.io/badge/version-1.3-00D9FF?style=flat-square)](https://github.com)

</div>

---

## Что это

Интерактивный bash-скрипт для быстрой первоначальной настройки Linux-серверов. Устанавливает и настраивает всё необходимое сразу после деплоя — без ручной возни с конфигами и без риска что-то пропустить.

ОС определяется автоматически. Правильные инструменты выбираются сами: UFW на Ubuntu, Firewalld на Rocky, systemd-resolved vs NetworkManager для DNS и так далее.

Каждый модуль проверяет текущее состояние системы и пропускает шаг если он уже выполнен — безопасно запускать повторно.

---

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/WayneFX36/server-setup/refs/heads/main/server-setup -o server-setup.sh
chmod +x server-setup.sh
sudo bash server-setup.sh
```

---

## Структура меню

```
┌─────────────────────────────────────────────────────┐
│                   ГЛАВНОЕ МЕНЮ                      │
├─────────────────────────────────────────────────────┤
│  [1]  Установка компонентов                         │
│       Базовая настройка: swap, dns, docker...       │
│                                                     │
│  [2]  Полная установка                              │
│       Сервер + Self SNI + Remnanode                 │
│                                                     │
│  [3]  Настройки                                     │
│       IP-фильтрация, SSH порт                       │
│                                                     │
│  [4]  Удалить скрипт                                │
└─────────────────────────────────────────────────────┘
```

### [1] Установка компонентов

```
  [1]   Swap файл (2GB)
  [2]   DNS (8.8.8.8 / 1.1.1.1)
  [3]   Системные пакеты + обновление
  [4]   Docker
  [5]   Файрвол (UFW / Firewalld)
  [6]   SSH порт → 29650
  [7]   Fail2ban
  [8]   Micro редактор
  [9]   Сетевые параметры (BBR + sysctl + отключение IPv6)
  [10]  SSH ключи / отключение пароля
  [11]  Очистка кеша
  [12]  Logrotate — RemnaNode
  [13]  Self SNI
  [14]  Remnanode
  ──────────────────────────────────────────────────────
  [15]  Установить всё (1–12, без SNI и ноды)
```

### [2] Полная установка

Запускает всё в правильном порядке — с возможностью продолжить с места остановки при обрыве:

```
  Шаг 1 / 3  →  Базовая настройка сервера (модули 1–12)
  Шаг 2 / 3  →  Self SNI  ⚠️ устанавливается ДО ноды
  Шаг 3 / 3  →  Remnanode
```

> **Важно:** Self SNI устанавливается до запуска Remnanode — после старта ноды порт 80/443 может быть занят, что помешает получить SSL-сертификат.

При повторном запуске после обрыва скрипт предложит:
- **Продолжить** — пропустит уже выполненные шаги
- **Начать заново** — полная переустановка

Перед запуском показывается статус IP-фильтрации: если не настроена — предупреждение что будет применён стандартный IP `1.1.1.1`.

### [3] Настройки

**IP-фильтрация порта ноды:**
```
  [1]  Добавить IP (один или несколько через запятую)
  [2]  Удалить IP по номеру
  [3]  Удалить все IP и сбросить правила
  [4]  Применить текущий список к файрволу
```

**SSH:**
```
  [5]  Сменить порт SSH
```

Текущий SSH порт и список разрешённых IP отображаются прямо в шапке меню настроек.

---

## Возможности

| Модуль | Ubuntu / Debian | Rocky / RHEL |
|---|---|---|
| **Swap** | `dd` + fstab | `dd` + fstab |
| **DNS** | systemd-resolved | NetworkManager + resolv.conf |
| **Пакеты** | apt + утилиты | dnf + EPEL |
| **Docker** | официальный репо Ubuntu | официальный репо CentOS |
| **Файрвол** | UFW | Firewalld |
| **SSH порт** | `ufw allow` | `semanage` + `firewall-cmd` |
| **Fail2ban** | action через UFW | action через iptables-ipset |
| **BBR + IPv6** | sysctl | sysctl |
| **Self SNI** | nginx + certbot | nginx + certbot |
| **Remnanode** | docker compose | docker compose |

---

## IP-фильтрация порта ноды

Ограничивает доступ к порту Remnanode только с указанных IP-адресов. Правила применяются через UFW на Ubuntu и через firewalld rich rules на Rocky/RHEL.

**Список IP хранится в:** `/etc/remnanode-allowed-ips.conf`

**Стандартный IP по умолчанию:** `1.1.1.1` — замени на IP своей панели управления.

Пример файла:
```
1.2.3.4
5.6.7.8
10.0.0.1/24
```

---

## Self SNI

Поднимает легитимный веб-сайт с валидным SSL-сертификатом на твоём домене и использует его как `target` в Xray Reality вместо стороннего домена.

```
Клиент → 443 (Xray/Reality) → 127.0.0.1:9000 (nginx) → сайт
```

После установки автоматически генерируется готовый конфиг Xray с ключами Reality и сохраняется в `/root/xray-config-<домен>.json`. Public Key выводится в терминал и дублируется в поле `_info` конфига.

**Шаблоны сайта на выбор:**

| № | Стиль |
|---|---|
| 1 | Бизнес / Корпоративный |
| 2 | Портфолио / Агентство |
| 3 | Технологии / SaaS |
| 4 | Блог / Медиа |
| 5 | Личный сайт |
| 6 | Случайный из коллекции |

**Параметры для Xray после установки:**
```json
"realitySettings": {
    "target": "127.0.0.1:9000",
    "privateKey": "<из конфига>",
    "serverNames": ["your.domain.com"]
}
```

---

## Remnanode

Устанавливает [Remnawave Node](https://github.com/remnawave) через Docker Compose. Скрипт запрашивает порт и Secret Key, создаёт `docker-compose.yml` и открывает порт в файрволе.

При повторном запуске — сравнивает порт и ключ с существующими:
- **Совпадают** → перезапуск контейнера с `docker compose pull`
- **Отличаются** → показывает разницу и спрашивает подтверждение на обновление

```yaml
services:
  remnanode:
    image: remnawave/node:latest
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=your_key
```

---

## Fail2ban: что настраивается

| Jail | Порог | Бан |
|---|---|---|
| `sshd` | 6 попыток | 1 час |
| `sshd-ddos` | 3 попытки за 5 мин | 2 часа |
| `recidive` | 5 банов за сутки | 1 неделя |

---

## Конфигурация

Переменные в начале скрипта:

```bash
NEW_SSH_PORT=29650        # новый порт SSH
FAIL2BAN_BANTIME="1h"     # время бана
FAIL2BAN_FINDTIME="10m"   # окно для подсчёта попыток
FAIL2BAN_MAXRETRY=3       # макс. попыток до бана
```

---

## Поддерживаемые ОС

| Дистрибутив | Версии |
|---|---|
| Ubuntu | 20.04, 22.04, 24.04 |
| Debian | 11, 12 |
| Rocky Linux | 8, 9 |
| AlmaLinux | 8, 9 |
| RHEL | 8, 9 |

---

## Важные замечания

- **SSH порт** — не закрывай сессию, пока не проверишь подключение на новом порту
- **Rocky + SELinux** — скрипт автоматически регистрирует SSH порт через `semanage`
- **Rocky + DNS** — `resolv.conf` защищается от перезаписи через `chattr +i`
- **Self SNI** — домен должен иметь A-запись, указывающую на IP сервера, до запуска скрипта
- **Порядок** — Self SNI всегда устанавливается до Remnanode
- **Идемпотентность** — каждый модуль проверяет текущее состояние и пропускает шаг если уже выполнен

---

## Полезные команды

```bash
# Fail2ban
fail2ban-client status sshd
fail2ban-client unban <IP>
tail -f /var/log/fail2ban.log

# Файрвол
ufw status verbose           # Ubuntu
firewall-cmd --list-all      # Rocky
firewall-cmd --list-rich-rules  # Rocky — IP-фильтрация

# Docker / Remnanode
docker ps
docker logs remnanode -f
cd /opt/remnanode && docker compose restart

# Nginx / Self SNI
nginx -t
systemctl reload nginx
certbot renew --dry-run
cat /root/xray-config-<домен>.json  # готовый конфиг Xray
```

---

## Лицензия

MIT
