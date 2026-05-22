<div align="center">

```
╔══════════════════════════════════════════════════════╗
║          SERVER SETUP  v1.0                          ║
║     Первоначальная настройка сервера за минуты       ║
╚══════════════════════════════════════════════════════╝
```

**Swap, DNS, Docker, файрвол, SSH, Fail2ban — одним скриптом.**

[![Bash](https://img.shields.io/badge/bash-5.0+-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![OS](https://img.shields.io/badge/OS-Ubuntu%20%7C%20Rocky%20%7C%20RHEL-orange?style=flat-square&logo=linux&logoColor=white)](https://github.com)

</div>

---

## Что это

Интерактивный bash-скрипт для быстрой первоначальной настройки Linux-серверов. Устанавливает и настраивает всё необходимое сразу после деплоя — без ручной возни с конфигами и без риска что-то пропустить.

ОС определяется автоматически. Правильные инструменты выбираются сами: UFW на Ubuntu, Firewalld на Rocky, systemd-resolved vs NetworkManager для DNS и так далее.

---

## Возможности

| Модуль | Ubuntu/Debian | Rocky/RHEL |
|---|---|---|
| **Swap** | `dd` + fstab | `dd` + fstab |
| **DNS** | systemd-resolved | NetworkManager + resolv.conf |
| **Пакеты** | apt + стандартные утилиты | dnf + EPEL |
| **Docker** | официальный репо Ubuntu | официальный репо CentOS |
| **Файрвол** | UFW | Firewalld |
| **SSH порт** | ufw allow | semanage + firewall-cmd |
| **Fail2ban** | action через UFW | action через iptables-ipset |
| **Сеть** | BBR + sysctl | BBR + sysctl |
| **Micro** | curl install | curl install |

### 🐛 Что пофикшено для Rocky Linux

- **DNS**: правильная настройка через NetworkManager вместо прямой записи в `resolv.conf` (который перезаписывается при перезагрузке)
- **SSH порт**: добавлен `semanage port` для регистрации порта в SELinux — без этого sshd не стартует на нестандартном порту
- **Fail2ban**: заменён сломанный `firewalld` action на `iptables-ipset-proto6` — rich rules в старых версиях fail2ban-firewalld работают нестабильно
- **SSH конфиг**: исправлен regex для смены порта — корректно обрабатывает все варианты (`#Port 22`, `Port 22`, отсутствие строки)

---

## Быстрый старт

**curl:**
```bash
curl -fsSL https://raw.githubusercontent.com/WayneFX36/server-setup/refs/heads/main/server-setup -o server-setup.sh
chmod +x server-setup.sh
sudo bash server-setup.sh
```

**wget:**
```bash
wget -q https://raw.githubusercontent.com/WayneFX36/server-setup/refs/heads/main/server-setup -O server-setup.sh
chmod +x server-setup.sh
sudo bash server-setup.sh
```

**Или сразу запустить без сохранения файла:**
```bash
curl -fsSL https://raw.githubusercontent.com/WayneFX36/server-setup/refs/heads/main/server-setup | sudo bash
```

Появится интерактивное меню. Выбираешь нужные модули или запускаешь всё сразу.

**Без меню:**

```bash
sudo bash server-setup.sh 12   # полная настройка (все модули)
sudo bash server-setup.sh 4    # только Docker
sudo bash server-setup.sh 7    # только Fail2ban
```

---

## Меню

```
  МОДУЛИ
  [1]   Swap файл (2GB)
  [2]   DNS (8.8.8.8 / 1.1.1.1)
  [3]   Системные пакеты + обновление
  [4]   Docker
  [5]   Файрвол (UFW на Ubuntu / Firewalld на Rocky)
  [6]   SSH порт → 29650
  [7]   Fail2ban
  [8]   Micro редактор
  [9]   Сетевые параметры (BBR + sysctl)
  [10]  SSH ключи / отключение пароля

  КОМБО
  [12]  Полная настройка (все модули подряд)
```

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

## Fail2ban: что настраивается

| Jail | Порог | Бан |
|---|---|---|
| `sshd` | 6 попыток | по умолчанию (1h) |
| `sshd-ddos` | 3 попытки за 5 мин | 2 часа |
| `recidive` | 5 банов за сутки | 1 неделя |

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

- **SSH порт**: не закрывай текущую сессию, пока не проверишь подключение на новом порту
- **Rocky + SELinux**: скрипт автоматически регистрирует новый SSH порт через `semanage`
- **Rocky + DNS**: `resolv.conf` защищается от перезаписи через `chattr +i` как запасной вариант
- Все sysctl сохраняются в `/etc/sysctl.d/99-server-setup.conf`

---

## Полезные команды после установки

```bash
# Статус и управление Fail2ban
fail2ban-client status sshd
fail2ban-client unban <IP>
tail -f /var/log/fail2ban.log

# Файрвол
ufw status verbose                  # Ubuntu
firewall-cmd --list-all             # Rocky

# Docker
docker ps
docker compose up -d
```

---

## Лицензия

MIT
