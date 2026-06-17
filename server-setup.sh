#!/usr/bin/env bash

# ============================================================
#  SERVER SETUP  v1.3  —  Первоначальная настройка сервера
#  Поддержка: Ubuntu 20.04/22.04/24.04
#             Rocky Linux 8/9, AlmaLinux 8/9, RHEL 8/9
# ============================================================

# ─── Конфигурация ────────────────────────────────────────────
NEW_SSH_PORT=29650
FAIL2BAN_BANTIME="1h"
FAIL2BAN_FINDTIME="10m"
FAIL2BAN_MAXRETRY=3

# ─── Цвета ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
step() { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }

# ─── Запуск шага с возможностью пропустить / повторить ───────
run_step() {
  local name="$1"
  local func="$2"
  while true; do
    if eval "$func"; then
      return 0
    else
      echo ""
      echo -e "${RED}  [✗] Шаг «${name}» завершился с ошибкой${NC}"
      echo -e "  ${CYAN}[1]${NC}  Повторить"
      echo -e "  ${CYAN}[2]${NC}  Пропустить и продолжить"
      echo -e "  ${RED}[0]${NC}  Прервать установку"
      echo ""
      echo -ne "${BOLD}  Выбор:${NC} "
      read -r step_choice
      case "$step_choice" in
        1) continue ;;
        2) warn "Шаг «${name}» пропущен"; return 0 ;;
        *) err "Установка прервана пользователем" ;;
      esac
    fi
  done
}

# ─── Спиннер ─────────────────────────────────────────────────
run_with_spinner() {
    local cmd=$1
    local msg=$2
    local log_file="/tmp/server_setup_$(date +%s)_$$.log"
    local spin=('|' '/' '-' '\\')
    local i=0
    eval "$cmd" >> "$log_file" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}${spin[$i]}${NC}  ${YELLOW}%s${NC}  " "$msg"
        i=$(( (i+1) % 4 ))
        sleep 0.15
    done
    wait "$pid"
    local exit_code=$?
    printf "\r                                                              \r"
    return $exit_code
}

# ─── Определение ОС ──────────────────────────────────────────
detect_os() {
  [[ -f /etc/os-release ]] || err "Не удалось определить ОС"
  . /etc/os-release
  OS_ID="${ID,,}"
  OS_VER="${VERSION_ID:-0}"
  OS_MAJOR="${OS_VER%%.*}"
  OS_PRETTY="${PRETTY_NAME:-$ID}"

  case "$OS_ID" in
    ubuntu|debian|linuxmint)
      FAMILY="debian" ;;
    rhel|centos|rocky|almalinux|ol|centos-stream)
      FAMILY="rhel" ;;
    *)
      err "Неподдерживаемая ОС: $OS_ID" ;;
  esac

  info "ОС: $OS_PRETTY  |  Семейство: $FAMILY"
}

require_root() {
  [[ $EUID -eq 0 ]] || err "Запусти скрипт от root: sudo bash $0"
}

# ═══════════════════════════════════════════════════════════════
#  БАЗОВЫЕ МОДУЛИ
# ═══════════════════════════════════════════════════════════════

setup_swap() {
  step "Swap файл (2GB)"
  if [ -f /swapfile ] && swapon --show | grep -q /swapfile; then
    local size
    size=$(swapon --show --bytes | grep /swapfile | awk '{print $3}')
    if [[ "$size" -ge 2000000000 ]]; then
      log "Swap уже настроен ($(free -h | awk '/Swap/{print $2}')) — пропускаю"
      return
    fi
    warn "Swap существует но меньше 2GB — пересоздаю..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
  fi
  dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q "/swapfile" /etc/fstab \
    || echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
  free -h
  log "Swap 2GB создан и добавлен в fstab"
}

setup_dns() {
  step "Настройка DNS (8.8.8.8 / 1.1.1.1)"
  if grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null && grep -q "1.1.1.1" /etc/resolv.conf 2>/dev/null; then
    log "DNS уже настроен (8.8.8.8 / 1.1.1.1) — пропускаю"
    return
  fi
  case "$FAMILY" in
    debian)
      cat > /etc/systemd/resolved.conf << 'EOF'
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=8.8.4.4 1.0.0.1
EOF
      systemctl restart systemd-resolved
      systemctl enable systemd-resolved
      if [ ! -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
        ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
      fi
      ;;
    rhel)
      if command -v nmcli &>/dev/null; then
        CONN=$(nmcli -t -f NAME,DEVICE con show --active | head -1 | cut -d: -f1)
        if [[ -n "$CONN" ]]; then
          nmcli con mod "$CONN" ipv4.dns "8.8.8.8 1.1.1.1" 2>/dev/null || true
          nmcli con mod "$CONN" ipv4.ignore-auto-dns yes 2>/dev/null || true
          nmcli con up "$CONN" 2>/dev/null || true
        fi
      fi
      chattr -i /etc/resolv.conf 2>/dev/null || true
      cat > /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
      chattr +i /etc/resolv.conf 2>/dev/null || \
        warn "Не удалось заблокировать resolv.conf — это нормально"
      ;;
  esac
  log "DNS настроен"
}

install_packages() {
  step "Обновление системы и базовые пакеты"
  case "$FAMILY" in
    debian)
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        nano vim net-tools htop wget curl ufw cron \
        socat tar gzip zip unzip logrotate \
        software-properties-common apt-transport-https \
        ca-certificates gnupg lsb-release \
        dnsutils bind9-dnsutils 2>/dev/null || \
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        nano vim net-tools htop wget curl ufw cron \
        socat tar gzip zip unzip logrotate \
        software-properties-common apt-transport-https \
        ca-certificates gnupg lsb-release dnsutils
      ;;
    rhel)
      dnf update -y
      dnf install -y epel-release || \
        dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm"
      dnf install -y \
        nano vim net-tools htop wget curl crontabs \
        socat tar gzip zip unzip logrotate \
        yum-utils ca-certificates
      ;;
  esac
  log "Пакеты установлены"
}

install_docker() {
  step "Установка Docker"
  if command -v docker &>/dev/null && systemctl is-active --quiet docker; then
    log "Docker уже установлен и запущен: $(docker --version | cut -d' ' -f3 | tr -d ',') — пропускаю"
    return
  fi
  case "$FAMILY" in
    debian)
      for pkg in docker.io docker-doc docker-compose docker-compose-v2 \
                 podman-docker containerd runc; do
        DEBIAN_FRONTEND=noninteractive apt-get remove -y "$pkg" 2>/dev/null || true
      done
      # Универсальный путь для Ubuntu и Debian
      install -m 0755 -d /etc/apt/keyrings
      # Определяем дистрибутив и правильный репо
      if [[ "$OS_ID" == "ubuntu" ]]; then
        local DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
      else
        local DOCKER_REPO_URL="https://download.docker.com/linux/debian"
      fi
      curl -fsSL "${DOCKER_REPO_URL}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
${DOCKER_REPO_URL} $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
      ;;
    rhel)
      dnf remove -y docker docker-client docker-client-latest docker-common \
        docker-latest docker-latest-logrotate docker-logrotate \
        docker-engine 2>/dev/null || true
      dnf config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo
      dnf install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
      ;;
  esac
  systemctl enable --now docker
  log "Docker $(docker --version | cut -d' ' -f3 | tr -d ',') установлен и запущен"
}

setup_firewall() {
  step "Настройка файрвола"
  case "$FAMILY" in
    debian)
      if systemctl is-active --quiet ufw && ufw status | grep -q "80/tcp\|443/tcp"; then
        log "UFW уже настроен — пропускаю"
        return
      fi
      systemctl stop firewalld 2>/dev/null || true
      systemctl disable firewalld 2>/dev/null || true
      apt-get install -y ufw
      ufw --force disable
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow 80/tcp  comment 'HTTP'
      ufw allow 443/tcp comment 'HTTPS'
      ufw --force enable
      ufw status verbose
      log "UFW настроен (80, 443 открыты)"
      ;;
    rhel)
      if systemctl is-active --quiet firewalld && \
         firewall-cmd --list-services 2>/dev/null | grep -q "http" && \
         firewall-cmd --list-services 2>/dev/null | grep -q "https"; then
        log "Firewalld уже настроен — пропускаю"
        return
      fi
      dnf install -y firewalld
      systemctl enable --now firewalld
      firewall-cmd --permanent --add-port=80/tcp
      firewall-cmd --permanent --add-port=443/tcp
      firewall-cmd --permanent --add-service=http
      firewall-cmd --permanent --add-service=https
      firewall-cmd --reload
      log "Firewalld настроен (80, 443 открыты)"
      ;;
  esac
}

setup_ssh_port() {
  step "Смена порта SSH → ${NEW_SSH_PORT}"
  local current_port
  current_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
  if [[ "$current_port" == "$NEW_SSH_PORT" ]]; then
    log "SSH уже слушает на порту ${NEW_SSH_PORT} — пропускаю"
    return
  fi
  cp /etc/ssh/sshd_config \
    "/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
  if grep -qE "^#?Port " /etc/ssh/sshd_config; then
    sed -i -E "s/^#?Port .*/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config
  else
    echo "Port ${NEW_SSH_PORT}" >> /etc/ssh/sshd_config
  fi
  case "$FAMILY" in
    debian)
      ufw allow "${NEW_SSH_PORT}/tcp" comment 'SSH'
      ufw delete allow 22/tcp 2>/dev/null || true
      ufw reload

      # Ubuntu 22.04+ использует ssh.socket — нужно обновить и его
      if systemctl list-units --type=socket 2>/dev/null | grep -q "ssh.socket"; then
        mkdir -p /etc/systemd/system/ssh.socket.d
        cat > /etc/systemd/system/ssh.socket.d/override.conf << EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${NEW_SSH_PORT}
ListenStream=[::]:${NEW_SSH_PORT}
EOF
        systemctl daemon-reload
        systemctl restart ssh.socket
        log "ssh.socket обновлён на порт ${NEW_SSH_PORT}"
      else
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
      fi
      ;;
    rhel)
      if command -v semanage &>/dev/null; then
        semanage port -a -t ssh_port_t -p tcp "${NEW_SSH_PORT}" 2>/dev/null \
          || semanage port -m -t ssh_port_t -p tcp "${NEW_SSH_PORT}" 2>/dev/null \
          || warn "semanage не сработал"
      else
        dnf install -y policycoreutils-python-utils 2>/dev/null || true
        semanage port -a -t ssh_port_t -p tcp "${NEW_SSH_PORT}" 2>/dev/null || true
      fi
      firewall-cmd --permanent --add-port="${NEW_SSH_PORT}/tcp"
      firewall-cmd --permanent --remove-service=ssh 2>/dev/null || true
      firewall-cmd --reload
      systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
      ;;
  esac
  log "SSH порт изменён на ${NEW_SSH_PORT}"
}

setup_fail2ban() {
  step "Fail2ban"
  if systemctl is-active --quiet fail2ban && [[ -f /etc/fail2ban/jail.local ]]; then
    log "Fail2ban уже установлен и запущен — пропускаю"
    return
  fi
  case "$FAMILY" in
    debian)
      apt-get install -y fail2ban
      cat > /etc/fail2ban/action.d/ufw.conf << 'EOF'
[Definition]
actionban   = ufw insert 1 deny from <ip> to any
actionunban = ufw delete deny from <ip> to any
EOF
      BANACTION="ufw"
      BANACTION_ALL="ufw"
      ;;
    rhel)
      dnf install -y fail2ban fail2ban-firewalld 2>/dev/null \
        || dnf install -y fail2ban
      BANACTION="iptables-ipset-proto6"
      BANACTION_ALL="iptables-allports"
      dnf install -y iptables 2>/dev/null || true
      ;;
  esac
  cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip     = 127.0.0.1/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
bantime      = ${FAIL2BAN_BANTIME}
findtime     = ${FAIL2BAN_FINDTIME}
maxretry     = ${FAIL2BAN_MAXRETRY}
banaction    = ${BANACTION}
banaction_allports = ${BANACTION_ALL}

[sshd]
enabled  = true
port     = ${NEW_SSH_PORT}
backend  = systemd
logpath  = %(sshd_log)s
maxretry = 6

[sshd-ddos]
enabled  = true
port     = ${NEW_SSH_PORT}
logpath  = %(sshd_log)s
maxretry = 3
findtime = 5m
bantime  = 2h

[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
maxretry = 5
findtime = 1d
bantime  = 1w
EOF
  cat > /etc/logrotate.d/fail2ban << 'EOF'
/var/log/fail2ban.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl reload fail2ban > /dev/null 2>&1 || true
    endscript
}
EOF
  systemctl enable --now fail2ban
  sleep 2
  fail2ban-client status sshd 2>/dev/null || warn "fail2ban sshd jail ещё стартует"
  log "Fail2ban настроен"
}

install_micro() {
  step "Micro редактор"
  if command -v micro &>/dev/null; then
    info "Micro уже установлен: $(micro --version 2>&1 | head -1)"
    return
  fi
  cd /tmp
  curl -fsSL https://getmic.ro | bash
  if [[ -f ./micro ]]; then
    mv ./micro /usr/local/bin/micro
    chmod +x /usr/local/bin/micro
    log "Micro установлен: $(micro --version 2>&1 | head -1)"
  else
    warn "Micro не скачался — пропускаю"
  fi
  cd - > /dev/null
}

tune_network() {
  step "Сетевые параметры (BBR + оптимизация + отключение IPv6)"
  if [[ -f /etc/sysctl.d/99-server-setup.conf ]] && \
     grep -q "tcp_bbr" /etc/sysctl.d/99-server-setup.conf && \
     grep -q "disable_ipv6" /etc/sysctl.d/99-server-setup.conf; then
    log "Сетевые параметры уже настроены — пропускаю"
    return
  fi
  modprobe tcp_bbr 2>/dev/null || true
  cat > /etc/sysctl.d/99-server-setup.conf << 'EOF'
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog  = 65536
net.core.somaxconn           = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fastopen        = 3
net.ipv4.tcp_mtu_probing     = 1
net.ipv4.tcp_syncookies      = 1
net.ipv4.tcp_syn_retries     = 2
net.ipv4.tcp_synack_retries  = 2
net.ipv4.tcp_fin_timeout     = 15
net.ipv4.tcp_keepalive_time  = 300
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl -p /etc/sysctl.d/99-server-setup.conf >/dev/null 2>&1 || true
  CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  log "Сеть настроена  |  CC: ${BOLD}${CC}${NC}  |  IPv6: отключён"
}

setup_ssh_security() {
  step "SSH безопасность (ключи / пароль)"
  if [[ ! -f /root/.ssh/authorized_keys ]] || [[ ! -s /root/.ssh/authorized_keys ]]; then
    warn "SSH ключи для root не найдены!"
    read -p "Добавить SSH ключ сейчас? (y/n): " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh
      echo "Вставьте публичный ключ и нажмите Ctrl+D:"
      cat >> /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      log "SSH ключ добавлен"
    fi
  fi
  read -p "Отключить вход по паролю SSH? (y/n): " -n 1 -r; echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
      /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    log "Вход по паролю отключён"
  else
    info "Вход по паролю оставлен"
  fi
}

setup_logrotate_remnanode() {
  step "Logrotate — RemnaNode"
  if [[ -f /etc/logrotate.d/remnanode ]]; then
    log "Logrotate для RemnaNode уже настроен — пропускаю"
    return
  fi
  if ! command -v logrotate &>/dev/null; then
    case "$FAMILY" in
      debian) apt-get install -y logrotate ;;
      rhel)   dnf install -y logrotate ;;
    esac
  fi
  mkdir -p /var/log/remnanode
  cat > /etc/logrotate.d/remnanode << 'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  logrotate -vf /etc/logrotate.d/remnanode 2>&1 | tail -3 || true
  log "Logrotate для RemnaNode настроен"
}

cleanup() {
  step "Очистка кеша"
  case "$FAMILY" in
    debian) apt-get clean; apt-get autoremove -y ;;
    rhel)   dnf clean all ;;
  esac
  log "Кеш очищен"
}

# ═══════════════════════════════════════════════════════════════
#  НОВЫЕ МОДУЛИ: Self SNI + Remnanode
# ═══════════════════════════════════════════════════════════════

install_selfsni() {
  step "Установка Self SNI"

  # Зависимости для SNI
  case "$FAMILY" in
    debian)
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        nginx certbot python3-certbot-nginx git curl \
        dnsutils bind9-dnsutils 2>/dev/null || \
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        nginx certbot python3-certbot-nginx git curl dnsutils
      # Ubuntu/Debian: webroot в /var/www/html
      NGINX_WEBROOT_BASE="/var/www/html"
      ;;
    rhel)
      dnf install -y epel-release 2>/dev/null || true
      dnf install -y nginx certbot python3-certbot-nginx git curl bind-utils
      # Rocky/RHEL: webroot в /usr/share/nginx/html
      NGINX_WEBROOT_BASE="/usr/share/nginx/html"
      ;;
  esac

  # Пересчитываем WEBROOT с правильным base
  case $TMPL in
    1|2|3|4|5) WEBROOT="${NGINX_WEBROOT_BASE}/dist" ;;
    *)          WEBROOT="${NGINX_WEBROOT_BASE}" ;;
  esac

  read -p "Введите доменное имя для SNI: " SNI_DOMAIN
  [[ -z "$SNI_DOMAIN" ]] && err "Доменное имя не может быть пустым"

  read -p "Внутренний SNI порт (Enter для 9000): " SNI_PORT
  SNI_PORT=${SNI_PORT:-9000}

  echo ""
  echo -e "${CYAN}Выберите шаблон сайта:${NC}"
  echo -e "  ${YELLOW}1)${NC} Бизнес / Корпоративный"
  echo -e "  ${YELLOW}2)${NC} Портфолио / Агентство"
  echo -e "  ${YELLOW}3)${NC} Технологии / SaaS"
  echo -e "  ${YELLOW}4)${NC} Блог / Медиа"
  echo -e "  ${YELLOW}5)${NC} Личный сайт"
  echo -e "  ${YELLOW}6)${NC} Случайный из коллекции"
  echo -e "  ${YELLOW}7)${NC} Свой шаблон (установлю сам)"
  read -p "Номер шаблона (Enter для 6): " TMPL
  TMPL=${TMPL:-6}

  local CUSTOM_TMPL=false
  case $TMPL in
    1) TMPL_URL="https://github.com/StartBootstrap/startbootstrap-creative.git";   WEBROOT="${NGINX_WEBROOT_BASE}/dist" ;;
    2) TMPL_URL="https://github.com/StartBootstrap/startbootstrap-freelancer.git"; WEBROOT="${NGINX_WEBROOT_BASE}/dist" ;;
    3) TMPL_URL="https://github.com/StartBootstrap/startbootstrap-new-age.git";    WEBROOT="${NGINX_WEBROOT_BASE}/dist" ;;
    4) TMPL_URL="https://github.com/StartBootstrap/startbootstrap-clean-blog.git"; WEBROOT="${NGINX_WEBROOT_BASE}/dist" ;;
    5) TMPL_URL="https://github.com/StartBootstrap/startbootstrap-resume.git";     WEBROOT="${NGINX_WEBROOT_BASE}/dist" ;;
    7) CUSTOM_TMPL=true; WEBROOT="${NGINX_WEBROOT_BASE}" ;;
    *) TMPL_URL="https://github.com/learning-zone/website-templates.git"; WEBROOT="${NGINX_WEBROOT_BASE}"; TMPL=6 ;;
  esac

  # Проверка DNS
  info "Проверка A-записи домена..."
  domain_ip=$(dig +short A "$SNI_DOMAIN" | head -n1)
  [[ -z "$domain_ip" ]] && err "Не удалось получить A-запись для $SNI_DOMAIN"

  # Получаем все IP адреса сервера
  all_server_ips=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.')
  # Также проверяем через внешний сервис
  external_ip=$(curl -s --max-time 5 https://api.ipify.org)
  [[ -n "$external_ip" ]] && all_server_ips=$(echo -e "$all_server_ips\n$external_ip")

  if ! echo "$all_server_ips" | grep -qx "$domain_ip"; then
    err "A-запись $SNI_DOMAIN ($domain_ip) не совпадает ни с одним IP сервера"
  fi
  log "DNS корректен: $SNI_DOMAIN → $domain_ip"

  # Остановка nginx и проверка портов
  systemctl stop nginx 2>/dev/null || true
  ss -tuln | grep -q ":443 " && err "Порт 443 занят"
  ss -tuln | grep -q ":80 "  && err "Порт 80 занят"

  # Открытие портов
  case "$FAMILY" in
    debian)
      ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true
      ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || true
      ;;
    rhel)
      if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service=http 2>/dev/null | grep -v "ALREADY_ENABLED" || true
        firewall-cmd --permanent --add-service=https 2>/dev/null | grep -v "ALREADY_ENABLED" || true
        firewall-cmd --reload > /dev/null 2>&1
      fi
      ;;
  esac

  # Шаблон сайта
  if [[ "$CUSTOM_TMPL" == "true" ]]; then
    mkdir -p "$NGINX_WEBROOT_BASE"
    info "Шаблон будет установлен вручную — инструкции в конце"
  else
    TEMP_DIR=$(mktemp -d)
    if run_with_spinner "git clone --depth 1 $TMPL_URL $TEMP_DIR" "Загрузка шаблона..."; then
      mkdir -p "$NGINX_WEBROOT_BASE"
      if [[ "$TMPL" == "6" ]]; then
        SITE_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | shuf -n 1)
        cp -r "$SITE_DIR"/* "$NGINX_WEBROOT_BASE"/ 2>/dev/null
      else
        cp -r "$TEMP_DIR"/* "$NGINX_WEBROOT_BASE"/ 2>/dev/null
      fi
      log "Шаблон установлен"
    else
      rm -rf "$TEMP_DIR"
      err "Не удалось загрузить шаблон"
    fi
    rm -rf "$TEMP_DIR"
  fi

  # SSL сертификат
  if run_with_spinner "certbot certonly --standalone -d $SNI_DOMAIN --agree-tos -m admin@$SNI_DOMAIN --non-interactive" "Получение SSL сертификата..."; then
    log "SSL сертификат получен"
  else
    err "Не удалось получить SSL сертификат"
  fi

  # Автопродление
  if systemctl list-timers 2>/dev/null | grep -q certbot.timer; then
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true
    if ! systemctl cat certbot.timer 2>/dev/null | grep -q "Persistent=true"; then
      mkdir -p /etc/systemd/system/certbot.timer.d/
      cat > /etc/systemd/system/certbot.timer.d/override.conf << 'EOF'
[Timer]
Persistent=true
EOF
      systemctl daemon-reload
      systemctl restart certbot.timer
    fi
    log "Автопродление: systemd timer"
  else
    cat > /etc/cron.d/certbot << 'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 */12 * * * root certbot -q renew --nginx
EOF
    log "Автопродление: cron"
  fi

  # Конфиг nginx
  rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  if [[ "$FAMILY" == "debian" ]]; then
    # Ubuntu/Debian: sites-available + симлинк
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat > "/etc/nginx/sites-available/sni.conf" << EOF
server {
    listen 80;
    server_name ${SNI_DOMAIN};
    if (\$host = ${SNI_DOMAIN}) {
        return 301 https://\$host\$request_uri;
    }
    return 404;
}

server {
    listen 127.0.0.1:${SNI_PORT} ssl http2;
    server_name ${SNI_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${SNI_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SNI_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
        root ${WEBROOT};
        try_files \$uri \$uri/ /index.html;
        index index.html;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/sni.conf /etc/nginx/sites-enabled/sni.conf
  else
    # Rocky/RHEL: conf.d
    cat > "/etc/nginx/conf.d/sni.conf" << EOF
server {
    listen 80;
    server_name ${SNI_DOMAIN};
    if (\$host = ${SNI_DOMAIN}) {
        return 301 https://\$host\$request_uri;
    }
    return 404;
}

server {
    listen 127.0.0.1:${SNI_PORT} ssl http2;
    server_name ${SNI_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${SNI_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SNI_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
        root ${WEBROOT};
        try_files \$uri \$uri/ /index.html;
        index index.html;
    }
}
EOF
    run_with_spinner "setsebool -P httpd_can_network_connect 1" "Настройка SELinux..." || true
  fi

  systemctl enable nginx > /dev/null 2>&1
  nginx -t > /dev/null 2>&1 && systemctl start nginx

  # Генерация конфига Xray
  step "Генерация конфига Xray Reality"

  # Генерируем ключи через openssl (x25519)
  local private_key public_key
  if command -v xray &>/dev/null; then
    local keypair
    keypair=$(xray x25519 2>/dev/null)
    private_key=$(echo "$keypair" | grep "Private" | awk '{print $3}')
    public_key=$(echo "$keypair" | grep "Public" | awk '{print $3}')
  else
    # Генерация через openssl если xray недоступен
    local raw_key
    raw_key=$(openssl genpkey -algorithm X25519 2>/dev/null)
    private_key=$(echo "$raw_key" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=')
    public_key=$(echo "$raw_key" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=')
  fi

  # Генерируем shortIds
  local short_ids=()
  for i in {1..5}; do
    short_ids+=("$(openssl rand -hex 4)")
  done

  # Тег из домена (первая часть до точки)
  local tag
  tag=$(echo "$SNI_DOMAIN" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')-tcp

  # Путь для сохранения конфига
  local conf_path="/root/xray-config-${SNI_DOMAIN}.json"

  cat > "$conf_path" << EOF
{
  "_info": {
    "_publicKey": "${public_key}",
    "_privateKey": "${private_key}",
    "_shortIds": "${short_ids[*]}",
    "_domain": "${SNI_DOMAIN}",
    "_dest": "127.0.0.1:${SNI_PORT}"
  },
  "log": {
    "error": "/var/log/remnanode/error.log",
    "access": "/var/log/remnanode/access.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "${tag}",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "target": "127.0.0.1:${SNI_PORT}",
          "shortIds": [
            "${short_ids[0]}",
            "${short_ids[1]}",
            "${short_ids[2]}",
            "${short_ids[3]}",
            "${short_ids[4]}"
          ],
          "privateKey": "${private_key}",
          "serverNames": [
            "${SNI_DOMAIN}",
            "www.${SNI_DOMAIN}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "ip": [
          "geoip:private"
        ],
        "type": "field",
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": [
          "geosite:category-ads-all"
        ],
        "outboundTag": "block"
      }
    ],
    "domainStrategy": "AsIs"
  }
}
EOF

  echo ""
  log "Self SNI установлен!"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
  echo -e "  ${YELLOW}Сертификат:${NC} /etc/letsencrypt/live/${SNI_DOMAIN}/fullchain.pem"
  echo -e "  ${YELLOW}Ключ:${NC}       /etc/letsencrypt/live/${SNI_DOMAIN}/privkey.pem"
  echo -e "  ${YELLOW}Dest:${NC}       127.0.0.1:${SNI_PORT}"
  echo -e "  ${YELLOW}SNI:${NC}        ${SNI_DOMAIN}"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"

  # Инструкции для кастомного шаблона
  if [[ "$CUSTOM_TMPL" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}  ┌─ Установка своего шаблона ──────────────────────┐${NC}"
    echo -e "${YELLOW}  │${NC}  Скопируй файлы сайта в директорию:             ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  ${BOLD}${NGINX_WEBROOT_BASE}${NC}  ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}                                                 ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  Например через scp с локальной машины:         ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  ${DIM}scp -r ./my-site/* root@$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "<IP>"):${NGINX_WEBROOT_BASE}/${NC}  ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}                                                 ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  Или клонировать репозиторий на сервере:        ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  ${DIM}cd ${NGINX_WEBROOT_BASE}${NC}  ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  ${DIM}git clone <url> .${NC}                              ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}                                                 ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  Если index.html не в корне, а в подпапке       ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  (например dist/), обнови путь в конфиге nginx: ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  ${DIM}nano /etc/nginx/conf.d/sni.conf${NC}  ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  Найди строку ${DIM}root${NC} и замени путь, затем:       ${YELLOW}│${NC}"
    echo -e "${YELLOW}  │${NC}  ${DIM}nginx -t && systemctl reload nginx${NC}             ${YELLOW}│${NC}"
    echo -e "${YELLOW}  └─────────────────────────────────────────────────┘${NC}"
  fi

  echo ""
  log "Конфиг Xray сохранён: ${conf_path}"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
  echo -e "  ${YELLOW}Private Key:${NC} ${private_key}"
  echo -e "  ${YELLOW}Public Key:${NC}  ${public_key}  ${DIM}← вставлять в панель${NC}"
  echo -e "  ${YELLOW}Short IDs:${NC}   ${short_ids[*]}"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
  echo -e "  ${DIM}Ключи также сохранены в поле _info конфига: ${conf_path}${NC}"
}

install_remnanode() {
  step "Установка Remnanode"
  read -p "Порт ноды (Enter для 2222): " NODE_PORT
  NODE_PORT=${NODE_PORT:-2222}
  read -p "Secret Key ноды: " SECRET_KEY
  [[ -z "$SECRET_KEY" ]] && err "Secret Key не может быть пустым"
  _remnanode_install "$NODE_PORT" "$SECRET_KEY"
}

# Внутренняя функция — устанавливает ноду с готовыми параметрами
_remnanode_install() {
  local NODE_PORT="$1"
  local SECRET_KEY="$2"

  # Проверяем существующую установку
  if [[ -f /opt/remnanode/docker-compose.yml ]]; then
    local existing_port existing_key
    existing_port=$(grep "NODE_PORT" /opt/remnanode/docker-compose.yml | grep -oE '[0-9]+' | head -1)
    existing_key=$(grep "SECRET_KEY" /opt/remnanode/docker-compose.yml | sed 's/.*SECRET_KEY=//' | tr -d '"' | tr -d "'" | tr -d ' ')

    if [[ "$existing_port" == "$NODE_PORT" && "$existing_key" == "$SECRET_KEY" ]]; then
      # Порт и ключ совпадают — просто перезапускаем
      info "Remnanode уже установлен с теми же параметрами — перезапускаю..."
      if run_with_spinner "cd /opt/remnanode && docker compose pull && docker compose up -d" "Перезапуск Remnanode..."; then
        log "Remnanode перезапущен"
      else
        err "Не удалось перезапустить Remnanode"
      fi
      echo ""
      echo -e "${CYAN}──────────────────────────────────────────${NC}"
      echo -e "  ${YELLOW}Порт:${NC}       ${NODE_PORT}"
      echo -e "  ${YELLOW}Secret Key:${NC} ${SECRET_KEY}"
      echo -e "  ${YELLOW}Статус:${NC}     перезапущен"
      echo -e "${CYAN}──────────────────────────────────────────${NC}"
      return
    else
      # Параметры отличаются — предупреждаем
      warn "Remnanode уже установлен с другими параметрами:"
      echo -e "  ${DIM}Текущий порт:  ${existing_port}  →  новый: ${NODE_PORT}${NC}"
      echo -e "  ${DIM}Текущий ключ:  ${existing_key:0:10}...  →  новый: ${SECRET_KEY:0:10}...${NC}"
      echo ""
      echo -ne "${BOLD}  Обновить конфиг и перезапустить? (y/n):${NC} "
      read -r update_confirm
      if [[ ! $update_confirm =~ ^[Yy]$ ]]; then
        info "Пропускаю установку Remnanode"
        return
      fi
      # Останавливаем перед обновлением
      run_with_spinner "cd /opt/remnanode && docker compose down" "Остановка Remnanode..." || true
    fi
  fi

  # Docker
  if ! command -v docker &>/dev/null; then
    info "Docker не найден — устанавливаю..."
    install_docker
  else
    log "Docker уже установлен"
  fi

  # Директории
  mkdir -p /opt/remnanode
  mkdir -p /var/log/remnanode

  # docker-compose.yml
  cat > /opt/remnanode/docker-compose.yml << EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${SECRET_KEY}
    volumes:
      - '/var/log/remnanode:/var/log/remnanode'
EOF
  log "docker-compose.yml создан: /opt/remnanode/docker-compose.yml"

  # Открытие порта в firewall
  case "$FAMILY" in
    debian)
      ufw allow "${NODE_PORT}/tcp" comment 'Remnanode' 2>/dev/null || true
      ufw reload 2>/dev/null || true
      log "Порт ${NODE_PORT} открыт в UFW"
      ;;
    rhel)
      if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${NODE_PORT}/tcp"
        firewall-cmd --reload
        log "Порт ${NODE_PORT} открыт в firewalld"
      fi
      ;;
  esac

  # Запуск
  if run_with_spinner "cd /opt/remnanode && docker compose up -d" "Запуск Remnanode..."; then
    log "Remnanode запущен"
  else
    err "Не удалось запустить Remnanode"
  fi

  echo ""
  log "Remnanode установлен!"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
  echo -e "  ${YELLOW}Порт:${NC}       ${NODE_PORT}"
  echo -e "  ${YELLOW}Secret Key:${NC} ${SECRET_KEY}"
  echo -e "  ${YELLOW}Compose:${NC}    /opt/remnanode/docker-compose.yml"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
}

# ═══════════════════════════════════════════════════════════════
#  IP-ФИЛЬТРАЦИЯ ПОРТА НОДЫ
# ═══════════════════════════════════════════════════════════════

IP_FILTER_CONF="/etc/remnanode-allowed-ips.conf"
DEFAULT_ALLOWED_IP="1.1.1.1"

# Читает текущий порт ноды из docker-compose.yml
get_node_port() {
  if [[ -f /opt/remnanode/docker-compose.yml ]]; then
    grep "NODE_PORT" /opt/remnanode/docker-compose.yml | grep -oE '[0-9]+' | head -1
  else
    echo "2222"
  fi
}

# Применяет правила файрвола для списка IP
apply_ip_rules() {
  local port=$1
  local ips=("${@:2}")

  case "$FAMILY" in
    debian)
      # Удаляем все старые правила для этого порта
      while ufw status numbered 2>/dev/null | grep -q "${port}"; do
        local num
        num=$(ufw status numbered 2>/dev/null | grep "${port}" | head -1 | awk -F'[][]' '{print $2}')
        [[ -z "$num" ]] && break
        ufw --force delete "$num" 2>/dev/null || break
      done
      # Добавляем по одному правилу на каждый IP
      for ip in "${ips[@]}"; do
        [[ -z "$ip" ]] && continue
        ufw allow from "$ip" to any port "$port" proto tcp comment "Remnanode" 2>/dev/null
      done
      ufw reload 2>/dev/null || true
      ;;
    rhel)
      if systemctl is-active --quiet firewalld; then
        # Удаляем старые rich rules для этого порта
        firewall-cmd --permanent --list-rich-rules 2>/dev/null | \
          grep "port=\"${port}\"" | while IFS= read -r rule; do
            firewall-cmd --permanent --remove-rich-rule="$rule" 2>/dev/null || true
          done
        # Удаляем простое правило для порта если было
        firewall-cmd --permanent --remove-port="${port}/tcp" 2>/dev/null || true
        # Добавляем rich rule для каждого IP
        for ip in "${ips[@]}"; do
          [[ -z "$ip" ]] && continue
          firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${ip}' port port='${port}' protocol='tcp' accept"
        done
        firewall-cmd --reload
      fi
      ;;
  esac
}

# Показывает текущие разрешённые IP
show_allowed_ips() {
  echo ""
  if [[ -f "$IP_FILTER_CONF" ]] && [[ -s "$IP_FILTER_CONF" ]]; then
    echo -e "${BOLD}  Разрешённые IP для порта ноды:${NC}"
    echo -e "${CYAN}  ──────────────────────────────────${NC}"
    local i=1
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      echo -e "  ${YELLOW}[$i]${NC}  $ip"
      ((i++))
    done < "$IP_FILTER_CONF"
    echo -e "${CYAN}  ──────────────────────────────────${NC}"
  else
    echo -e "  ${YELLOW}[!]${NC}  IP-фильтрация не настроена"
    echo -e "  ${DIM}  Стандартный IP: ${DEFAULT_ALLOWED_IP}${NC}"
  fi
  echo ""
}

# Главный модуль управления IP-фильтрацией
menu_settings() {
  while true; do
    print_banner
    info "ОС: $OS_PRETTY"
    local node_port
    node_port=$(get_node_port)
    local current_ssh_port
    current_ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "$NEW_SSH_PORT")
    echo ""
    echo -e "${BOLD}  НАСТРОЙКИ${NC}"
    echo ""

    # Статус IP-фильтрации
    echo -e "  ${BOLD}IP-фильтрация порта ноды${NC} ${DIM}(порт: ${node_port})${NC}"
    if [[ -f "$IP_FILTER_CONF" ]] && [[ -s "$IP_FILTER_CONF" ]]; then
      local i=1
      while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        echo -e "    ${YELLOW}[$i]${NC} $ip"
        ((i++))
      done < "$IP_FILTER_CONF"
    else
      echo -e "    ${DIM}Не настроена (стандартный: ${DEFAULT_ALLOWED_IP})${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}SSH порт:${NC} ${GREEN}${current_ssh_port}${NC}"
    echo ""

    echo -e "${BOLD}  IP-фильтрация${NC}"
    echo -e "  ${CYAN}[1]${NC}  Добавить IP"
    echo -e "  ${CYAN}[2]${NC}  Удалить IP по номеру"
    echo -e "  ${CYAN}[3]${NC}  Удалить все IP и сбросить правила"
    echo -e "  ${CYAN}[4]${NC}  Применить текущий список к файрволу"
    echo ""
    echo -e "${BOLD}  SSH${NC}"
    echo -e "  ${CYAN}[5]${NC}  Сменить порт SSH"
    echo ""
    echo -e "  ${RED}[0]${NC}  ← Назад"
    echo ""
    echo -ne "${BOLD}Выбор:${NC} "
    read -r choice

    case "$choice" in
      1)
        echo ""
        read -p "  Введите IP (или несколько через запятую): " input_ips
        if [[ -z "$input_ips" ]]; then
          warn "IP не введён"
        else
          touch "$IP_FILTER_CONF"
          IFS=',' read -ra new_ips <<< "$input_ips"
          local added=0
          for raw_ip in "${new_ips[@]}"; do
            local ip
            ip=$(echo "$raw_ip" | tr -d ' ')
            [[ -z "$ip" ]] && continue
            if ! echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]+)?$'; then
              warn "Некорректный IP: $ip — пропускаю"
              continue
            fi
            if grep -qx "$ip" "$IP_FILTER_CONF" 2>/dev/null; then
              warn "IP $ip уже есть в списке"
            else
              echo "$ip" >> "$IP_FILTER_CONF"
              log "Добавлен: $ip"
              ((added++)) || true
            fi
          done
          if [[ $added -gt 0 ]]; then
            mapfile -t all_ips < "$IP_FILTER_CONF"
            apply_ip_rules "$node_port" "${all_ips[@]}"
            log "Правила файрвола обновлены"
          fi
        fi
        ;;
      2)
        if [[ ! -f "$IP_FILTER_CONF" ]] || [[ ! -s "$IP_FILTER_CONF" ]]; then
          warn "Список пуст — нечего удалять"
        else
          read -p "  Введите номер IP для удаления: " del_num
          if [[ "$del_num" =~ ^[0-9]+$ ]]; then
            del_ip=$(sed -n "${del_num}p" "$IP_FILTER_CONF")
            if [[ -n "$del_ip" ]]; then
              sed -i "${del_num}d" "$IP_FILTER_CONF"
              log "Удалён: $del_ip"
              mapfile -t all_ips < "$IP_FILTER_CONF"
              if [[ ${#all_ips[@]} -gt 0 ]]; then
                apply_ip_rules "$node_port" "${all_ips[@]}"
              else
                case "$FAMILY" in
                  debian)
                    while ufw status numbered 2>/dev/null | grep -q "${node_port}"; do
                      local num
                      num=$(ufw status numbered 2>/dev/null | grep "${node_port}" | head -1 | awk -F'[][]' '{print $2}')
                      [[ -z "$num" ]] && break
                      ufw --force delete "$num" 2>/dev/null || break
                    done
                    ufw reload 2>/dev/null || true
                    ;;
                  rhel)
                    firewall-cmd --permanent --list-rich-rules 2>/dev/null | \
                      grep "port=\"${node_port}\"" | while IFS= read -r rule; do
                        firewall-cmd --permanent --remove-rich-rule="$rule" 2>/dev/null || true
                      done
                    firewall-cmd --permanent --remove-port="${node_port}/tcp" 2>/dev/null || true
                    firewall-cmd --reload 2>/dev/null || true
                    ;;
                esac
                warn "Список IP пуст — порт ${node_port} закрыт для всех"
              fi
              log "Правила файрвола обновлены"
            else
              warn "Номер не найден"
            fi
          else
            warn "Введи корректный номер"
          fi
        fi
        ;;
      3)
        echo ""
        echo -ne "${RED}  Удалить все IP и сбросить правила? (y/n):${NC} "
        read -r confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
          > "$IP_FILTER_CONF"
          case "$FAMILY" in
            debian)
              while ufw status numbered 2>/dev/null | grep -q "${node_port}"; do
                local num
                num=$(ufw status numbered 2>/dev/null | grep "${node_port}" | head -1 | awk -F'[][]' '{print $2}')
                [[ -z "$num" ]] && break
                ufw --force delete "$num" 2>/dev/null || break
              done
              ufw allow "${node_port}/tcp" comment 'Remnanode' 2>/dev/null || true
              ufw reload 2>/dev/null || true
              ;;
            rhel)
              firewall-cmd --permanent --list-rich-rules 2>/dev/null | \
                grep "port=\"${node_port}\"" | while IFS= read -r rule; do
                  firewall-cmd --permanent --remove-rich-rule="$rule" 2>/dev/null || true
                done
              firewall-cmd --permanent --add-port="${node_port}/tcp" 2>/dev/null || true
              firewall-cmd --reload 2>/dev/null || true
              ;;
          esac
          log "Все IP удалены, порт ${node_port} открыт для всех"
        fi
        ;;
      4)
        if [[ ! -f "$IP_FILTER_CONF" ]] || [[ ! -s "$IP_FILTER_CONF" ]]; then
          warn "Список IP пуст — нечего применять"
        else
          mapfile -t all_ips < "$IP_FILTER_CONF"
          apply_ip_rules "$node_port" "${all_ips[@]}"
          log "Правила файрвола применены для ${#all_ips[@]} IP"
        fi
        ;;
      5)
        echo ""
        echo -e "  ${DIM}Текущий порт SSH: ${current_ssh_port}${NC}"
        read -p "  Новый порт SSH: " new_ssh
        if [[ -z "$new_ssh" ]]; then
          warn "Порт не введён"
        elif ! [[ "$new_ssh" =~ ^[0-9]+$ ]] || [[ "$new_ssh" -lt 1 ]] || [[ "$new_ssh" -gt 65535 ]]; then
          warn "Некорректный порт: $new_ssh"
        else
          NEW_SSH_PORT="$new_ssh"
          setup_ssh_port
        fi
        ;;
      0) break ;;
      *) warn "Неверный выбор: $choice" ;;
    esac

    echo ""
    echo -ne "${DIM}Нажми Enter для продолжения...${NC}"
    read -r
  done
}

# ═══════════════════════════════════════════════════════════════
#  ИТОГОВЫЙ ВЫВОД
# ═══════════════════════════════════════════════════════════════

print_summary() {
  LOCAL_IP=$(hostname -I | awk '{print $1}')
  PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "?")
  echo ""
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Настройка завершена!${NC}"
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}"
  echo ""
  echo -e "  ${BOLD}Сервисы:${NC}"
  echo -e "  Docker   → $(systemctl is-active docker 2>/dev/null || echo 'N/A')"
  case "$FAMILY" in
    debian) echo -e "  UFW      → $(systemctl is-active ufw 2>/dev/null || echo 'N/A')" ;;
    rhel)   echo -e "  Firewall → $(systemctl is-active firewalld 2>/dev/null || echo 'N/A')" ;;
  esac
  echo -e "  Fail2ban → $(systemctl is-active fail2ban 2>/dev/null || echo 'N/A')"
  echo -e "  Nginx    → $(systemctl is-active nginx 2>/dev/null || echo 'N/A')"
  echo -e "  SSH      → $(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || echo 'N/A')"
  echo ""
  echo -e "  ${BOLD}Swap:${NC}   $(free -h | awk '/Swap/{print $2}')"
  echo -e "  ${BOLD}TCP CC:${NC} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo ""
  echo -e "  ${BOLD}${RED}ВАЖНО!${NC} Проверь новый SSH порт до закрытия сессии:"
  echo -e "  ${BOLD}ssh -p ${NEW_SSH_PORT} root@${PUBLIC_IP}${NC}"
  echo ""
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Полезные команды:${NC}"
  echo -e "${DIM}  fail2ban-client status sshd${NC}"
  echo -e "${DIM}  docker ps${NC}"
  echo -e "${DIM}  docker logs remnanode${NC}"
  case "$FAMILY" in
    debian) echo -e "${DIM}  ufw status verbose${NC}" ;;
    rhel)   echo -e "${DIM}  firewall-cmd --list-all${NC}" ;;
  esac
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}"
  echo ""
}

# ═══════════════════════════════════════════════════════════════
#  МЕНЮ
# ═══════════════════════════════════════════════════════════════

print_banner() {
  clear
  echo -e "${BOLD}${CYAN}"
  cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║          SERVER SETUP  v1.3                          ║
  ║    Ubuntu • Rocky Linux • AlmaLinux • RHEL           ║
  ╚══════════════════════════════════════════════════════╝
BANNER
  echo -e "${NC}"
}

# ─── Меню 1: Установка компонентов ───────────────────────────
menu_components() {
  while true; do
    print_banner
    info "ОС: $OS_PRETTY"
    echo ""
    echo -e "${BOLD}  УСТАНОВКА КОМПОНЕНТОВ${NC}"
    echo -e "  ${DIM}Базовая настройка сервера${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  Swap файл (2GB)"
    echo -e "  ${CYAN}[2]${NC}  DNS (8.8.8.8 / 1.1.1.1)"
    echo -e "  ${CYAN}[3]${NC}  Системные пакеты + обновление"
    echo -e "  ${CYAN}[4]${NC}  Docker"
    echo -e "  ${CYAN}[5]${NC}  Файрвол ${DIM}(UFW / Firewalld)${NC}"
    echo -e "  ${CYAN}[6]${NC}  SSH порт → ${NEW_SSH_PORT}"
    echo -e "  ${CYAN}[7]${NC}  Fail2ban"
    echo -e "  ${CYAN}[8]${NC}  Micro редактор"
    echo -e "  ${CYAN}[9]${NC}  Сетевые параметры (BBR + sysctl)"
    echo -e "  ${CYAN}[10]${NC} SSH ключи / отключение пароля"
    echo -e "  ${CYAN}[11]${NC} Очистка кеша"
    echo -e "  ${CYAN}[12]${NC} Logrotate — RemnaNode"
    echo -e "  ${CYAN}[13]${NC} Self SNI"
    echo -e "  ${CYAN}[14]${NC} Remnanode"
    echo ""
    echo -e "  ${GREEN}[15]${NC} ${BOLD}Установить всё${NC} ${DIM}(настройка сервера без ноды и SNI)${NC}"
    echo ""
    echo -e "  ${RED}[0]${NC}  ← Назад"
    echo ""
    echo -ne "${BOLD}Выбор:${NC} "
    read -r choice

    case "$choice" in
      1)  setup_swap ;;
      2)  setup_dns ;;
      3)  install_packages ;;
      4)  install_docker ;;
      5)  setup_firewall ;;
      6)  setup_ssh_port ;;
      7)  setup_fail2ban ;;
      8)  install_micro ;;
      9)  tune_network ;;
      10) setup_ssh_security ;;
      11) cleanup ;;
      12) setup_logrotate_remnanode ;;
      13) install_selfsni ;;
      14) install_remnanode ;;
      15)
        setup_swap
        setup_dns
        install_packages
        install_docker
        setup_firewall
        setup_ssh_port
        setup_fail2ban
        install_micro
        tune_network
        setup_ssh_security
        setup_logrotate_remnanode
        cleanup
        print_summary
        ;;
      0) break ;;
      *) warn "Неверный выбор: $choice" ;;
    esac

    echo ""
    echo -ne "${DIM}Нажми Enter для возврата в меню...${NC}"
    read -r
  done
}

# ─── Меню 2: Полная установка ────────────────────────────────
STATE_FILE="/etc/server-setup-state"

# Записывает выполненный шаг
state_set() { echo "$1" >> "$STATE_FILE"; }

# Проверяет выполнен ли шаг
state_done() { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }

# Сбрасывает состояние
state_reset() { rm -f "$STATE_FILE"; }

menu_full_install() {
  print_banner
  info "ОС: $OS_PRETTY"
  echo ""
  echo -e "${BOLD}${CYAN}  ПОЛНАЯ УСТАНОВКА${NC}"
  echo -e "  ${DIM}Настройка сервера + Self SNI + Remnanode${NC}"
  echo ""

  # Проверяем незавершённую установку
  if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
    echo -e "${YELLOW}  [!] Обнаружена незавершённая установка!${NC}"
    echo -e "  ${DIM}Выполненные шаги:${NC}"
    while IFS= read -r s; do
      echo -e "  ${GREEN}  ✓${NC} $s"
    done < "$STATE_FILE"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  Продолжить с места остановки"
    echo -e "  ${CYAN}[2]${NC}  Начать заново"
    echo -e "  ${RED}[0]${NC}  Отмена"
    echo ""
    echo -ne "${BOLD}  Выбор:${NC} "
    read -r resume_choice
    case "$resume_choice" in
      1) info "Продолжаю установку..." ;;
      2) state_reset; info "Начинаю заново..." ;;
      *) return ;;
    esac
    echo ""
    # Восстанавливаем сохранённые параметры
    if state_done "SNI_CHOICE=y" || state_done "SNI_CHOICE=Y"; then
      install_sni_choice="y"
    else
      install_sni_choice="n"
    fi
    FULL_NODE_PORT=$(grep "^NODE_PORT=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    FULL_SECRET_KEY=$(grep "^SECRET_KEY=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    FULL_PANEL_IP=$(grep "^PANEL_IP=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    FULL_NODE_PORT=${FULL_NODE_PORT:-2222}
  else
    echo -e "${YELLOW}  Порядок установки:${NC}"
    echo -e "  ${DIM}1. Базовая настройка сервера${NC}"
    echo -e "  ${DIM}2. Self SNI — устанавливается ДО ноды (важно!)${NC}"
    echo -e "  ${DIM}3. Remnanode — запускается последним${NC}"
    echo ""
    echo -ne "${BOLD}  Начать полную установку? (y/n):${NC} "
    read -r confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && return

    echo ""
    echo -e "${BOLD}${CYAN}  ── Параметры установки ──────────────────────────${NC}"
    echo ""

    # Self SNI
    echo -ne "${BOLD}  Установить Self SNI? (y/n):${NC} "
    read -r install_sni_choice

    # IP панели
    if [[ -f "$IP_FILTER_CONF" ]] && [[ -s "$IP_FILTER_CONF" ]]; then
      echo ""
      echo -e "  ${GREEN}[✓] IP-фильтрация уже настроена:${NC}"
      while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        echo -e "  ${DIM}    • $ip${NC}"
      done < "$IP_FILTER_CONF"
      FULL_PANEL_IP=""
    else
      echo ""
      read -p "  IP панели управления (Enter = пропустить, настроить позже): " FULL_PANEL_IP
    fi

    # Порт ноды и ключ
    echo ""
    read -p "  Порт ноды (Enter для 2222): " FULL_NODE_PORT
    FULL_NODE_PORT=${FULL_NODE_PORT:-2222}
    read -p "  Secret Key ноды: " FULL_SECRET_KEY
    if [[ -z "$FULL_SECRET_KEY" ]]; then
      warn "Secret Key не может быть пустым"
      return
    fi

    # Итоговый экран подтверждения
    echo ""
    echo -e "${CYAN}  ──────────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}Self SNI:   $(echo "$install_sni_choice" | grep -qi y && echo "да" || echo "нет")${NC}"
    echo -e "  ${DIM}Порт ноды:  ${FULL_NODE_PORT}${NC}"
    echo -e "  ${DIM}Secret Key: ${FULL_SECRET_KEY:0:8}...${NC}"
    [[ -n "$FULL_PANEL_IP" ]] && echo -e "  ${DIM}IP панели:  ${FULL_PANEL_IP}${NC}"
    echo -e "${CYAN}  ──────────────────────────────────────────────────${NC}"
    echo ""
    echo -ne "${BOLD}  Всё верно? (y/n):${NC} "
    read -r final_confirm
    [[ ! $final_confirm =~ ^[Yy]$ ]] && return

    # Сохраняем параметры в state
    echo "SNI_CHOICE=${install_sni_choice}" > "$STATE_FILE"
    echo "NODE_PORT=${FULL_NODE_PORT}" >> "$STATE_FILE"
    echo "SECRET_KEY=${FULL_SECRET_KEY}" >> "$STATE_FILE"
    [[ -n "$FULL_PANEL_IP" ]] && echo "PANEL_IP=${FULL_PANEL_IP}" >> "$STATE_FILE"
    [[ -n "$FULL_PANEL_IP" ]] && echo "$FULL_PANEL_IP" > "$IP_FILTER_CONF"
  fi

  # 1. Базовая настройка (setup_ssh_security убрана — интерактивная)
  if ! state_done "base_setup"; then
    step "ШАГ 1/3 — Базовая настройка сервера"
    run_step "Swap"              setup_swap
    run_step "DNS"               setup_dns
    run_step "Пакеты"            install_packages
    run_step "Docker"            install_docker
    run_step "Файрвол"           setup_firewall
    run_step "SSH порт"          setup_ssh_port
    run_step "Fail2ban"          setup_fail2ban
    run_step "Micro"             install_micro
    run_step "Сеть BBR"          tune_network
    run_step "Logrotate"         setup_logrotate_remnanode
    run_step "Очистка"           cleanup
    state_set "base_setup"
  else
    info "ШАГ 1/3 — Базовая настройка уже выполнена, пропускаю"
  fi

  # 2. Self SNI (обязательно до ноды)
  if [[ $install_sni_choice =~ ^[Yy]$ ]]; then
    if ! state_done "selfsni"; then
      echo ""
      echo -e "${BOLD}${CYAN}══ ШАГ 2/3 — Self SNI ${DIM}(устанавливается до ноды)${NC}"
      run_step "Self SNI" install_selfsni
      state_set "selfsni"
    else
      info "ШАГ 2/3 — Self SNI уже установлен, пропускаю"
    fi
  else
    info "Self SNI пропущен"
  fi

  # 3. Remnanode с уже собранными параметрами
  if ! state_done "remnanode"; then
    echo ""
    step "ШАГ 3/3 — Remnanode"
    run_step "Remnanode" "_remnanode_install \"$FULL_NODE_PORT\" \"$FULL_SECRET_KEY\""
    state_set "remnanode"
  else
    info "ШАГ 3/3 — Remnanode уже установлен, пропускаю"
  fi

  # Применяем IP-фильтрацию
  local node_port
  node_port=$(get_node_port)
  if [[ -f "$IP_FILTER_CONF" ]] && [[ -s "$IP_FILTER_CONF" ]]; then
    mapfile -t all_ips < "$IP_FILTER_CONF"
    apply_ip_rules "$node_port" "${all_ips[@]}"
    log "IP-фильтрация применена для порта ${node_port}"
  else
    echo ""
    echo -e "${YELLOW}  [!] IP-фильтрация не настроена — порт ${node_port} открыт для всех${NC}"
    echo -e "${YELLOW}  [!] Настрой IP в пункте [3] Настройки главного меню${NC}"
  fi

  state_reset
  print_summary
}


# ─── Главное меню ────────────────────────────────────────────
main_menu() {
  while true; do
    print_banner
    info "ОС: $OS_PRETTY"
    echo ""
    echo -e "${BOLD}  ГЛАВНОЕ МЕНЮ${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установка компонентов${NC}"
    echo -e "       ${DIM}Базовая настройка: swap, dns, docker, firewall, ssh...${NC}"
    echo ""
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Полная установка${NC}"
    echo -e "       ${DIM}Настройка сервера + Self SNI + Remnanode${NC}"
    echo ""
    echo -e "  ${CYAN}[3]${NC}  ${BOLD}Настройки${NC}"
    echo -e "       ${DIM}IP-фильтрация, SSH порт${NC}"
    if [[ -f "$IP_FILTER_CONF" ]] && [[ -s "$IP_FILTER_CONF" ]]; then
      local ip_count
      ip_count=$(grep -c . "$IP_FILTER_CONF" 2>/dev/null || echo 0)
      echo -e "       ${GREEN}✓ IP-фильтр: ${ip_count} IP${NC}"
    else
      echo -e "       ${YELLOW}⚠ IP-фильтр не настроен${NC}"
    fi
    echo ""
    echo -e "  ${RED}[4]${NC}  ${BOLD}Удалить скрипт${NC}"
    echo -e "       ${DIM}Удалить файл скрипта с сервера${NC}"
    echo ""
    echo -e "  ${RED}[0]${NC}  Выход"
    echo ""
    echo -ne "${BOLD}Выбор:${NC} "
    read -r choice

    case "$choice" in
      1) menu_components ;;
      2) menu_full_install
         echo ""
         echo -ne "${DIM}Нажми Enter для возврата в меню...${NC}"
         read -r
         ;;
      3) menu_settings ;;
      4)
        echo ""
        echo -ne "${RED}  Удалить скрипт ${BASH_SOURCE[0]}? (y/n):${NC} "
        read -r del_confirm
        if [[ $del_confirm =~ ^[Yy]$ ]]; then
          rm -f "${BASH_SOURCE[0]}"
          log "Скрипт удалён"
          exit 0
        fi
        ;;
      0) echo -e "\n${DIM}Пока!${NC}\n"; exit 0 ;;
      *) warn "Неверный выбор: $choice" ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════

main() {
  require_root
  detect_os
  main_menu
}

main "$@"
