#!/bin/bash

# Цвета вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

BACKUP_DIR="/root/server-setup-backups"

create_backup() {
  local source_file="$1"
  local timestamp
  local backup_file

  if ! sudo test -e "$source_file"; then
    return 0
  fi

  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_file="$BACKUP_DIR/$(basename "$source_file").$timestamp"
  sudo mkdir -p "$BACKUP_DIR" || return 1
  sudo cp -a "$source_file" "$backup_file" || return 1
  echo "$backup_file"
}

restore_backup() {
  local backup_file="$1"
  local target_file="$2"

  if [[ -n "$backup_file" ]] && sudo test -e "$backup_file"; then
    sudo cp -a "$backup_file" "$target_file"
  else
    sudo rm -f "$target_file"
  fi
}

systemd_unit_exists() {
  local unit_name="$1"

  if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit_name"; then
    return 0
  fi

  if [[ "$unit_name" != *.* ]] &&
     systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit_name.service"; then
    return 0
  fi

  return 1
}

######### SSH ########


check_ssh_settings() {
  echo -e "${CYAN}==== Эффективные настройки SSH ====${RESET}"
  sudo sshd -T | grep -E '^(passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries|permitrootlogin) '
}

block_ssh_access_by_password() {
  local config_file="/etc/ssh/sshd_config.d/99-custom.conf"
  local backup_file=""
  local login_user="${SUDO_USER:-${USER:-root}}"
  local login_home
  local temp_file

  echo -e "${CYAN}==== Блокируем доступ к SSH по паролю ====${RESET}"

  login_home=$(getent passwd "$login_user" | cut -d: -f6)
  if [[ -z "$login_home" ]] ||
     { [[ ! -s "$login_home/.ssh/authorized_keys" ]] && sudo test ! -s /root/.ssh/authorized_keys; }; then
    echo -e "${RED}Не найден ни один непустой authorized_keys.${RESET}"
    echo "Сначала настройте и проверьте вход по SSH-ключу, затем повторите операцию."
    return 1
  fi

  backup_file=$(create_backup "$config_file") || return 1
  temp_file=$(mktemp) || return 1

  cat > "$temp_file" <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
MaxAuthTries 5
EOF

  sudo mkdir -p /etc/ssh/sshd_config.d || return 1
  sudo install -m 600 "$temp_file" "$config_file" || {
    rm -f "$temp_file"
    return 1
  }
  rm -f "$temp_file"

  if ! sudo sshd -t; then
    echo -e "${RED}Новая конфигурация SSH не прошла проверку. Возвращаем предыдущий файл.${RESET}"
    restore_backup "$backup_file" "$config_file"
    sudo sshd -t || echo -e "${RED}После отката конфигурация SSH всё ещё содержит ошибку.${RESET}"
    return 1
  fi

  reload_ssh || {
    echo -e "${RED}Не удалось перезагрузить SSH. Возвращаем предыдущую конфигурацию.${RESET}"
    restore_backup "$backup_file" "$config_file"
    sudo sshd -t && reload_ssh
    return 1
  }

  check_ssh_settings
  echo "Не закрывайте текущую сессию, пока не проверите вход по ключу во втором терминале."
}

check_ssh_connection_by_password() {
  echo -e "${CYAN}==== Проверка эффективной настройки входа по паролю ====${RESET}"

  if sudo sshd -T | grep -qx 'passwordauthentication no'; then
    echo -e "${GREEN}Вход по паролю отключён в эффективной конфигурации SSH.${RESET}"
  else
    echo -e "${RED}Вход по паролю не отключён в эффективной конфигурации SSH.${RESET}"
    return 1
  fi
}

reload_ssh() {
  local service_name="ssh"

  if systemd_unit_exists sshd.service && ! systemd_unit_exists ssh.service; then
    service_name="sshd"
  fi

  sudo systemctl reload "$service_name" || return 1
  sudo systemctl is-active --quiet "$service_name" || return 1
  echo -e "${GREEN}Служба $service_name перечитала конфигурацию и остаётся активной.${RESET}"
}

find_ssh_configs(){
  sudo grep -RnsE '^(Include|PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin|MaxAuthTries)' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null
}

has_sudo_admin_key() {
  local sudo_members
  local admin_user
  local admin_home
  local -a admin_users=()

  sudo_members=$(getent group sudo | cut -d: -f4)
  IFS=',' read -r -a admin_users <<< "$sudo_members"

  for admin_user in "${admin_users[@]}"; do
    [[ -n "$admin_user" ]] || continue
    admin_home=$(getent passwd "$admin_user" | cut -d: -f6)
    if [[ -n "$admin_home" ]] && sudo test -s "$admin_home/.ssh/authorized_keys"; then
      return 0
    fi
  done

  return 1
}

configure_root_ssh_access() {
  local config_file="/etc/ssh/sshd_config.d/98-root-access.conf"
  local backup_file=""
  local root_mode
  local confirmation
  local temp_file

  echo "1. Разрешить root только по SSH-ключу"
  echo "2. Полностью запретить вход root по SSH"
  echo "0. Отмена"
  read -rp "Выберите режим: " root_mode

  case "$root_mode" in
    1) root_mode="prohibit-password" ;;
    2) root_mode="no" ;;
    0) return 0 ;;
    *) echo -e "${RED}Неверный выбор.${RESET}"; return 1 ;;
  esac

  if [[ "$root_mode" == "no" ]]; then
    if ! has_sudo_admin_key; then
      echo -e "${RED}Не найден альтернативный администратор из группы sudo с установленным SSH-ключом.${RESET}"
      echo "Сначала создайте администратора, установите ключ и проверьте вход."
      return 1
    fi
    echo -e "${YELLOW}Вход root по SSH будет полностью запрещён.${RESET}"
  fi

  read -rp "Применить PermitRootLogin $root_mode? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена."
    return 0
  fi

  backup_file=$(create_backup "$config_file") || return 1
  temp_file=$(mktemp) || return 1
  printf 'PermitRootLogin %s\n' "$root_mode" > "$temp_file"
  sudo install -m 600 "$temp_file" "$config_file" || {
    rm -f "$temp_file"
    return 1
  }
  rm -f "$temp_file"

  if ! sudo sshd -t; then
    echo -e "${RED}Конфигурация SSH не прошла проверку. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$config_file"
    return 1
  fi

  reload_ssh || {
    restore_backup "$backup_file" "$config_file"
    sudo sshd -t && reload_ssh
    return 1
  }

  check_ssh_settings
  echo "Проверьте вход в новой сессии до закрытия текущего подключения."
}

######### Пользователи ########

create_new_user() {
  local username

  echo "Создание нового пользователя..."
  read -rp "Введите имя пользователя: " username

  if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo -e "${RED}Недопустимое имя пользователя.${RESET}"
    return 1
  fi

  if getent passwd "$username" >/dev/null; then
    echo -e "${YELLOW}Пользователь $username уже существует.${RESET}"
    return 0
  fi

  sudo adduser "$username"
}

install_user_ssh_key() {
  local username
  local user_home
  local public_key

  read -rp "Введите имя пользователя: " username
  if ! getent passwd "$username" >/dev/null; then
    echo -e "${RED}Пользователь $username не найден.${RESET}"
    return 1
  fi

  read -rp "Вставьте публичный SSH-ключ одной строкой: " public_key
  if [[ ! "$public_key" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
    echo -e "${RED}Строка не похожа на поддерживаемый публичный SSH-ключ.${RESET}"
    return 1
  fi

  user_home=$(getent passwd "$username" | cut -d: -f6)
  sudo install -d -m 700 -o "$username" -g "$username" "$user_home/.ssh" || return 1
  if ! sudo grep -qxF "$public_key" "$user_home/.ssh/authorized_keys" 2>/dev/null; then
    printf '%s\n' "$public_key" | sudo tee -a "$user_home/.ssh/authorized_keys" >/dev/null || return 1
  fi
  sudo chown "$username:$username" "$user_home/.ssh/authorized_keys" || return 1
  sudo chmod 600 "$user_home/.ssh/authorized_keys" || return 1
  echo -e "${GREEN}Ключ установлен пользователю $username.${RESET}"
}

create_admin_user() {
  local username
  local confirmation

  read -rp "Введите имя нового администратора: " username
  if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo -e "${RED}Недопустимое имя пользователя.${RESET}"
    return 1
  fi

  if ! getent passwd "$username" >/dev/null; then
    sudo adduser "$username" || return 1
  fi

  read -rp "Добавить пользователя $username в группу sudo? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Пользователь создан без административных прав."
    return 0
  fi

  sudo usermod -aG sudo "$username" || return 1
  echo -e "${GREEN}Пользователь $username добавлен в группу sudo.${RESET}"
  echo "Теперь установите ему SSH-ключ и проверьте вход в отдельной сессии."
}

######### Fail2Ban ########

NGINX_ACCESS_LOG="/var/log/nginx/access.log"
EXIM_LOG="/var/log/exim4/mainlog"
FAIL2BAN_CONFIG="/etc/fail2ban/jail.d/99-server-setup.conf"

install_fail2ban() {
  echo "Устанавливаем Fail2Ban..."
  sudo apt-get update || return 1
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban || return 1
  sudo systemctl enable --now fail2ban || return 1
  sudo systemctl is-active --quiet fail2ban || return 1
  echo -e "${GREEN}Fail2Ban установлен, включён в автозагрузку и запущен.${RESET}"
}

setup_fail2ban_base() {
  local backup_file=""
  local temp_file

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    echo -e "${RED}Fail2Ban не установлен. Сначала выполните пункт установки.${RESET}"
    return 1
  fi

  echo "Настраиваем защиту SSH и доступные фильтры Nginx..."

  sudo mkdir -p /etc/fail2ban/jail.d
  backup_file=$(create_backup "$FAIL2BAN_CONFIG") || return 1
  temp_file=$(mktemp) || return 1

  cat > "$temp_file" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
maxretry = 5
EOF

  if [[ -f /etc/fail2ban/filter.d/nginx-botsearch.conf && -f "$NGINX_ACCESS_LOG" ]]; then
    cat >> "$temp_file" <<EOF

[nginx-botsearch]
enabled = true
logpath = $NGINX_ACCESS_LOG
EOF
  fi

  if [[ -f /etc/fail2ban/filter.d/nginx-noscript.conf && -f "$NGINX_ACCESS_LOG" ]]; then
    cat >> "$temp_file" <<EOF

[nginx-noscript]
enabled = true
logpath = $NGINX_ACCESS_LOG
EOF
  fi

  if [[ -f /etc/fail2ban/filter.d/exim.conf && -f "$EXIM_LOG" ]]; then
    cat >> "$temp_file" <<EOF

[exim]
enabled = true
logpath = $EXIM_LOG
EOF
  fi

  sudo install -m 640 "$temp_file" "$FAIL2BAN_CONFIG" || {
    rm -f "$temp_file"
    return 1
  }
  rm -f "$temp_file"

  if ! sudo fail2ban-client -t; then
    echo -e "${RED}Конфигурация Fail2Ban не прошла проверку. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$FAIL2BAN_CONFIG"
    sudo fail2ban-client -t || echo -e "${RED}После отката конфигурация Fail2Ban всё ещё содержит ошибку.${RESET}"
    return 1
  fi

  if ! sudo systemctl restart fail2ban || ! sudo systemctl is-active --quiet fail2ban; then
    echo -e "${RED}Fail2Ban не запустился с новой конфигурацией. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$FAIL2BAN_CONFIG"
    sudo fail2ban-client -t && sudo systemctl restart fail2ban
    return 1
  fi

  echo -e "${GREEN}Конфигурация Fail2Ban применена.${RESET}"
  sudo fail2ban-client status
}

check_fail2ban() {
  echo "Общий статус Fail2Ban:"
  sudo systemctl status fail2ban --no-pager
  sudo fail2ban-client status
}

check_jail() {
  local jail

  echo "Доступные jail:"
  sudo fail2ban-client status
  echo ""
  read -rp "Введите имя jail (например, sshd): " jail
  if [[ ! "$jail" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}Недопустимое имя jail.${RESET}"
    return 1
  fi
  sudo fail2ban-client status "$jail"
}

fail2ban_log() {
  echo "Для выхода из просмотра нажмите Ctrl+C."
  sudo tail -f /var/log/fail2ban.log
}

######### Автоматические обновления безопасности ########

UNATTENDED_CONFIG="/etc/apt/apt.conf.d/20auto-upgrades"
UNATTENDED_ORIGINS_CONFIG="/etc/apt/apt.conf.d/52-server-setup-security-updates"

setup_security_updates() {
  local backup_file=""
  local origins_backup_file=""
  local temp_file
  local origins_temp_file

  echo "Устанавливаем unattended-upgrades..."
  sudo apt-get update || return 1
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades || return 1

  backup_file=$(create_backup "$UNATTENDED_CONFIG") || return 1
  origins_backup_file=$(create_backup "$UNATTENDED_ORIGINS_CONFIG") || return 1
  temp_file=$(mktemp) || return 1
  origins_temp_file=$(mktemp) || {
    rm -f "$temp_file"
    return 1
  }
  cat > "$temp_file" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  sudo install -m 644 "$temp_file" "$UNATTENDED_CONFIG" || {
    rm -f "$temp_file" "$origins_temp_file"
    return 1
  }
  rm -f "$temp_file"

  cat > "$origins_temp_file" <<'EOF'
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "codename=${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  sudo install -m 644 "$origins_temp_file" "$UNATTENDED_ORIGINS_CONFIG" || {
    rm -f "$origins_temp_file"
    restore_backup "$backup_file" "$UNATTENDED_CONFIG"
    return 1
  }
  rm -f "$origins_temp_file"

  if ! sudo unattended-upgrade --dry-run; then
    echo -e "${RED}Проверочный запуск unattended-upgrades завершился с ошибкой. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$UNATTENDED_CONFIG"
    restore_backup "$origins_backup_file" "$UNATTENDED_ORIGINS_CONFIG"
    return 1
  fi

  if ! sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer; then
    echo -e "${RED}Не удалось включить таймеры APT. Выполняем откат конфигурации.${RESET}"
    restore_backup "$backup_file" "$UNATTENDED_CONFIG"
    restore_backup "$origins_backup_file" "$UNATTENDED_ORIGINS_CONFIG"
    return 1
  fi
  echo -e "${GREEN}Автоматическая установка обновлений безопасности включена.${RESET}"
  echo "Автоматически устанавливаются только пакеты из репозитория с кодовым именем *-security."
}

check_security_updates() {
  echo -e "${CYAN}=== Автоматические обновления безопасности ===${RESET}"
  dpkg-query -W -f='${Status} ${Version}\n' unattended-upgrades 2>/dev/null || echo "Пакет не установлен."
  systemctl status apt-daily.timer apt-daily-upgrade.timer --no-pager || true
  systemctl list-timers 'apt-daily*' --all --no-pager || true
  echo
  echo "Эффективная конфигурация периодических обновлений:"
  apt-config dump | grep -E 'APT::Periodic|Unattended-Upgrade::(Allowed-Origins|Origins-Pattern)' || true
}

security_updates_log() {
  echo "Для выхода из просмотра нажмите Ctrl+C."
  sudo tail -n 100 -f /var/log/unattended-upgrades/unattended-upgrades.log
}



######### Система ########

system_info() {
  echo -e "${GREEN}Выполняю: cat /etc/os-release ${RESET}"
  cat /etc/os-release
  echo -e "${GREEN}Выполняю: hostnamectl ${RESET}"
  hostnamectl
}

all_services() {
  echo -e "${GREEN}Выполняю: systemctl list-units --type=service --no-pager ${RESET}"
  systemctl list-units --type=service --no-pager
}

system_log() {
  echo "Для выхода из просмотра нажмите Ctrl+C."
  echo -e "${GREEN}Выполняю: sudo tail -n 100 -f /var/log/syslog ${RESET}"
  sudo tail -n 100 -f /var/log/syslog
}

security_service_inventory() {
  local service_name
  local -a services=(
    ssh sshd nginx apache2
    proftpd vsftpd pure-ftpd telnet telnet.socket
    mysql mariadb postgresql redis-server
    exim4 postfix dovecot
    fail2ban netfilter-persistent
  )

  echo -e "${CYAN}=== Инвентаризация потенциально значимых служб ===${RESET}"
  for service_name in "${services[@]}"; do
    if systemd_unit_exists "$service_name"; then
      printf '%-24s active=%-10s enabled=%s\n' \
        "$service_name" \
        "$(systemctl is-active "$service_name" 2>/dev/null || true)" \
        "$(systemctl is-enabled "$service_name" 2>/dev/null || true)"
    fi
  done

  echo
  echo "Слушающие процессы:"
  sudo ss -lntup
}

disable_unneeded_service() {
  local service_name
  local confirmation
  local candidate
  local -a allowed_services=(
    proftpd vsftpd pure-ftpd telnet telnet.socket
    mysql mariadb postgresql redis-server
    exim4 postfix dovecot
  )
  local allowed=0

  security_service_inventory
  echo
  read -rp "Введите точное имя службы, которую нужно остановить и отключить: " service_name

  for candidate in "${allowed_services[@]}"; do
    if [[ "$service_name" == "$candidate" ]]; then
      allowed=1
      break
    fi
  done

  if ((allowed == 0)); then
    echo -e "${RED}Эта служба не входит в ограниченный список отключаемых сервисов.${RESET}"
    echo "Для нестандартной службы сначала проверьте её назначение вручную."
    return 1
  fi

  if ! systemd_unit_exists "$service_name"; then
    echo "Служба $service_name не установлена."
    return 0
  fi

  echo -e "${YELLOW}Остановка базы данных или почтовой службы может нарушить работу сайтов и почты.${RESET}"
  read -rp "Введите точное имя '$service_name' ещё раз для подтверждения: " confirmation
  if [[ "$confirmation" != "$service_name" ]]; then
    echo "Операция отменена."
    return 0
  fi

  sudo systemctl disable --now "$service_name" || return 1
  echo -e "${GREEN}Служба $service_name остановлена и отключена из автозагрузки.${RESET}"
  echo "Для возврата: sudo systemctl enable --now $service_name"
}

######### nginx  ########

nginx_status() {
  echo -e "${GREEN}Выполняю: sudo systemctl status nginx --no-pager ${RESET}"
  sudo systemctl status nginx --no-pager
}

nginx_reload() {
  echo -e "${GREEN}Проверяем конфигурацию: sudo nginx -t ${RESET}"
  sudo nginx -t || {
    echo -e "${RED}Конфигурация Nginx содержит ошибку. Перезагрузка отменена.${RESET}"
    return 1
  }

  sudo systemctl reload nginx || return 1
  sudo systemctl is-active --quiet nginx || return 1
  echo -e "${GREEN}Nginx перечитал проверенную конфигурацию и остаётся активным.${RESET}"
}

######### Сеть ########

open_ports() {
  echo -e "${GREEN}Выполняю: sudo ss -lntup ${RESET}"
  sudo ss -lntup
}

filesystem_security_audit() {
  local web_root="/var/www"

  echo -e "${CYAN}=== Проверка безопасности файловой системы ===${RESET}"

  if [[ ! -d "$web_root" ]]; then
    echo "Каталог $web_root отсутствует."
    return 0
  fi

  echo
  echo -e "${BLUE}Файлы и каталоги с правами записи для всех в $web_root:${RESET}"
  sudo find "$web_root" -xdev -perm -0002 -printf '%m %u:%g %p\n' 2>/dev/null || true

  echo
  echo -e "${BLUE}Потенциально чувствительные конфигурационные файлы:${RESET}"
  sudo find "$web_root" -xdev -type f \
    \( -name '.env' -o -name 'configuration.php' -o -name 'wp-config.php' -o -name '*.key' -o -name '*.pem' \) \
    -printf '%m %u:%g %p\n' 2>/dev/null || true

  echo
  echo -e "${BLUE}Чувствительные конфигурационные файлы, доступные для чтения всем:${RESET}"
  sudo find "$web_root" -xdev -type f -perm -0004 \
    \( -name '.env' -o -name 'configuration.php' -o -name 'wp-config.php' -o -name '*.key' -o -name '*.pem' \) \
    -printf '%m %u:%g %p\n' 2>/dev/null || true

  echo
  echo -e "${BLUE}Приватные SSH-файлы с доступом для группы или остальных:${RESET}"
  sudo find /root /home -xdev -type f -path '*/.ssh/*' ! -name '*.pub' \
    -perm /077 -printf '%m %u:%g %p\n' 2>/dev/null || true

  echo
  echo -e "${BLUE}Каталоги веб-сайтов, принадлежащие www-data и доступные ему для записи:${RESET}"
  sudo find "$web_root" -xdev -type d -user www-data -perm -u+w \
    -printf '%m %u:%g %p\n' 2>/dev/null || true

  echo
  echo "Пустой раздел означает, что соответствующие проблемы не найдены."
  echo "Найденные writable-каталоги нужно оценивать вручную: cache, logs и uploads могут быть легитимными."
}

collect_security_report() {
  local service_name

  echo -e "${CYAN}=== Аудит безопасности без изменения системы ===${RESET}"
  echo
  echo -e "${BLUE}Система:${RESET}"
  grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
  uname -r

  echo
  echo -e "${BLUE}Эффективные настройки SSH:${RESET}"
  sudo sshd -T 2>/dev/null |
    grep -E '^(passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries|permitrootlogin) ' || true

  echo
  echo -e "${BLUE}Службы безопасности и сетевые службы:${RESET}"
  for service_name in ssh sshd nginx fail2ban netfilter-persistent proftpd; do
    if systemd_unit_exists "$service_name"; then
      printf '%-24s active=%-10s enabled=%s\n' \
        "$service_name" \
        "$(systemctl is-active "$service_name" 2>/dev/null || true)" \
        "$(systemctl is-enabled "$service_name" 2>/dev/null || true)"
    fi
  done

  echo
  echo -e "${BLUE}Все активные службы:${RESET}"
  systemctl list-units --type=service --state=running --no-pager

  echo
  echo -e "${BLUE}Открытые TCP/UDP-порты:${RESET}"
  sudo ss -lntup

  echo
  echo -e "${BLUE}Пользователи с UID 0:${RESET}"
  awk -F: '$3 == 0 {print $1 " (" $7 ")"}' /etc/passwd

  echo
  echo -e "${BLUE}Пользователи с интерактивной оболочкой:${RESET}"
  awk -F: '$7 !~ /(nologin|false)$/ {print $1 " uid=" $3 " shell=" $7}' /etc/passwd

  echo
  echo -e "${BLUE}Группа sudo:${RESET}"
  getent group sudo || true

  echo
  echo -e "${BLUE}Установленные SSH-ключи пользователей:${RESET}"
  while IFS= read -r authorized_keys_file; do
    echo "$authorized_keys_file"
    sudo ssh-keygen -lf "$authorized_keys_file" 2>/dev/null || echo "  Не удалось прочитать ключи."
  done < <(sudo find /root /home -xdev -type f -path '*/.ssh/authorized_keys' 2>/dev/null)

  echo
  echo -e "${BLUE}Fail2Ban:${RESET}"
  if command -v fail2ban-client >/dev/null 2>&1; then
    sudo fail2ban-client status || true
  else
    echo "Fail2Ban не установлен."
  fi

  echo
  echo -e "${BLUE}Фаервол INPUT:${RESET}"
  sudo iptables -w 5 -L INPUT -n -v --line-numbers
  sudo ip6tables -w 5 -L INPUT -n -v --line-numbers

  echo
  echo -e "${BLUE}Сохранение правил фаервола:${RESET}"
  systemctl is-enabled netfilter-persistent 2>/dev/null || true
  systemctl is-active netfilter-persistent 2>/dev/null || true

  echo
  echo -e "${BLUE}Автоматические обновления:${RESET}"
  systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true
  systemctl is-active apt-daily-upgrade.timer 2>/dev/null || true
  apt-config dump | grep -E 'APT::Periodic|Unattended-Upgrade::(Allowed-Origins|Origins-Pattern)' || true

  echo
  echo -e "${BLUE}Доступные обновления пакетов:${RESET}"
  apt list --upgradable 2>/dev/null || true

  echo
  echo -e "${GREEN}Аудит завершён. Скрипт ничего не изменял.${RESET}"
}

security_audit() {
  collect_security_report
}

save_security_report() {
  local report_file

  report_file="${PWD}/server-security-report-$(date +%Y%m%d-%H%M%S).txt"
  {
    collect_security_report
    echo
    filesystem_security_audit
  } 2>&1 | tee "$report_file"
  echo
  echo -e "${GREEN}Отчёт сохранён: $report_file${RESET}"
}

# Подменю nginx
nginx_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Nginx ===${RESET}"
    echo "1. Показать статус Nginx"
    echo "2. Проверить конфигурацию и перечитать её"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) nginx_status ;;
    2) nginx_reload ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю system
system_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Система ===${RESET}"
    echo "1. Информация о системе"
    echo "2. Все сервисы"
    echo "3. Системные логи"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) system_info ;;
    2) all_services ;;
    3) system_log ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю пользователей
user_settings_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Пользователи ===${RESET}"
    echo "1. Создать нового пользователя"
    echo "2. Создать администратора с правами sudo"
    echo "3. Установить публичный SSH-ключ пользователю"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) create_new_user ;;
    2) create_admin_user ;;
    3) install_user_ssh_key ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю сети
network_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Сеть ===${RESET}"
    echo "1. Открытые порты"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) open_ports ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю Fail2ban
fail2ban_settings_menu() {
  while true; do
    echo ""
    echo "=== Fail2Ban ==="
    echo "1. Установить Fail2Ban"
    echo "2. Показать общий статус"
    echo "3. Показать статус определённого jail"
    echo "4. Настроить защиту SSH и доступные фильтры Nginx"
    echo "5. Смотреть журнал"
    echo "0. Назад"

    read -rp "Выберите действие [0-5]: " CHOICE

    case $CHOICE in
      1) install_fail2ban ;;
      2) check_fail2ban ;;
      3) check_jail ;;
      4) setup_fail2ban_base ;;
      5) fail2ban_log ;;
      0) break ;;
      *) echo "Неверный выбор." ;;
    esac
  done
}

# Подменю SSH
ssh_settings_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== SSH ===${RESET}"
    echo "1. Проверить SSH настройки"
    echo "2. Заблокировать доступ к SSH по паролю"
    echo "3. Проверить, отключён ли пароль в эффективной конфигурации"
    echo "4. Найти настройки во всех SSH-конфигах"
    echo "5. Настроить доступ root по SSH"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) check_ssh_settings ;;
    2) block_ssh_access_by_password ;;
    3) check_ssh_connection_by_password ;;
    4) find_ssh_configs ;;
    5) configure_root_ssh_access ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

security_updates_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Автоматические обновления безопасности ===${RESET}"
    echo "1. Установить и включить security-обновления"
    echo "2. Проверить состояние и таймеры"
    echo "3. Смотреть журнал unattended-upgrades"
    echo "0. Назад в главное меню"
    read -rp "Выберите действие: " CHOICE

    case $CHOICE in
      1) setup_security_updates ;;
      2) check_security_updates ;;
      3) security_updates_log ;;
      0) break ;;
      *) echo "Неверный выбор." ;;
    esac
  done
}

services_security_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Инвентаризация служб ===${RESET}"
    echo "1. Показать значимые службы и открытые порты"
    echo "2. Остановить и отключить выбранную ненужную службу"
    echo "0. Назад в главное меню"
    read -rp "Выберите действие: " CHOICE

    case $CHOICE in
      1) security_service_inventory ;;
      2) disable_unneeded_service ;;
      0) break ;;
      *) echo "Неверный выбор." ;;
    esac
  done
}

rules_iptables() {
  echo -e "${GREEN}Выполняю: sudo iptables -L -n --line-numbers ${RESET}"
  sudo iptables -w 5 -L -n --line-numbers
}

backup_firewall_rules() {
  local timestamp
  local backup_path

  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_path="$BACKUP_DIR/firewall-$timestamp"
  sudo mkdir -p "$backup_path" || return 1
  sudo iptables-save | sudo tee "$backup_path/rules.v4" >/dev/null || return 1
  sudo ip6tables-save | sudo tee "$backup_path/rules.v6" >/dev/null || return 1

  if command -v ipset >/dev/null 2>&1; then
    sudo ipset save | sudo tee "$backup_path/ipsets" >/dev/null || return 1
  fi

  echo "$backup_path"
}

restore_firewall_rules() {
  local backup_path="$1"

  if [[ -z "$backup_path" ]] || ! sudo test -d "$backup_path"; then
    echo -e "${RED}Каталог резервной копии фаервола не найден.${RESET}"
    return 1
  fi

  if sudo test -s "$backup_path/ipsets" && command -v ipset >/dev/null 2>&1; then
    sudo ipset restore -exist -file "$backup_path/ipsets" || return 1
  fi
  sudo iptables-restore "$backup_path/rules.v4" || return 1
  sudo ip6tables-restore "$backup_path/rules.v6" || return 1
  echo -e "${GREEN}Активные правила восстановлены из $backup_path.${RESET}"
}

setup_iptables_persistence() {
  local -a required_packages=("iptables-persistent")
  local -a missing_packages=()
  local package_name

  # Правила ISPmanager могут ссылаться на динамические наборы ipset. В таком
  # случае наборы необходимо восстанавливать раньше правил IPv4 и IPv6.
  if sudo iptables-save | grep -q -- '--match-set' ||
     sudo ip6tables-save | grep -q -- '--match-set'; then
    required_packages+=("ipset-persistent")
  fi

  for package_name in "${required_packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null |
         grep -q '^install ok installed$'; then
      missing_packages+=("$package_name")
    fi
  done

  if ((${#missing_packages[@]} > 0)); then
    echo "Устанавливаем пакеты для автоматического восстановления фаервола: ${missing_packages[*]}"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}" || return 1
  fi

  sudo systemctl enable netfilter-persistent || return 1
  sudo netfilter-persistent save || return 1

  if [[ -f /etc/iptables/ipsets ]] && command -v ipset >/dev/null 2>&1; then
    sudo ipset restore -exist -file /etc/iptables/ipsets || return 1
  fi

  sudo iptables-restore --test /etc/iptables/rules.v4 || return 1
  sudo ip6tables-restore --test /etc/iptables/rules.v6 || return 1

  echo -e "${GREEN}Правила сохранены через netfilter-persistent.${RESET}"
  echo "IPv4: /etc/iptables/rules.v4"
  echo "IPv6: /etc/iptables/rules.v6"

  if [[ -f /etc/iptables/ipsets ]]; then
    echo "IP-наборы: /etc/iptables/ipsets"
  fi

  echo "Служба включена в автозагрузку:"
  sudo systemctl is-enabled netfilter-persistent
}

check_iptables_persistence() {
  echo -e "${CYAN}=== Состояние сохранения правил фаервола ===${RESET}"
  sudo systemctl is-enabled netfilter-persistent || true
  sudo systemctl is-active netfilter-persistent || true

  for rules_file in /etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/iptables/ipsets; do
    if sudo test -f "$rules_file"; then
      sudo ls -lh "$rules_file"
    else
      echo "Файл отсутствует: $rules_file"
    fi
  done

  if sudo test -f /etc/iptables/rules.v4; then
    sudo iptables-restore --test /etc/iptables/rules.v4
  fi
  if sudo test -f /etc/iptables/rules.v6; then
    sudo ip6tables-restore --test /etc/iptables/rules.v6
  fi
}

is_valid_ipv4() {
  local ip="$1"
  local octet
  local -a octets=()

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

restrict_ispmanager_access() {
  local chain_name="ISPMGR_ACCESS"
  local chain6_name="ISPMGR6_ACCESS"
  local detected_ip=""
  local allowed_ip_input
  local allowed_ip
  local confirmation
  local firewall_backup
  local -a allowed_ips=()

  echo -e "${CYAN}=== Ограничение доступа к ISPmanager ===${RESET}"
  echo "Будет разрешён доступ к TCP-порту 1500 только с указанных IPv4-адресов."

  if [[ -n "${SSH_CLIENT:-}" ]]; then
    detected_ip="${SSH_CLIENT%% *}"
    echo "IP текущего SSH-подключения: $detected_ip"
  fi

  read -rp "Введите разрешённые IPv4-адреса через пробел${detected_ip:+ [по умолчанию: $detected_ip]}: " allowed_ip_input

  if [[ -z "$allowed_ip_input" && -n "$detected_ip" ]]; then
    allowed_ip_input="$detected_ip"
  fi

  # Разрешаем вводить адреса как через пробел, так и через запятую.
  allowed_ip_input="${allowed_ip_input//,/ }"

  for allowed_ip in $allowed_ip_input; do
    if ! is_valid_ipv4 "$allowed_ip"; then
      echo -e "${RED}Некорректный IPv4-адрес: $allowed_ip. Правила не изменены.${RESET}"
      return 1
    fi
    allowed_ips+=("$allowed_ip")
  done

  if ((${#allowed_ips[@]} == 0)); then
    echo -e "${RED}Не указан ни один разрешённый IPv4-адрес. Правила не изменены.${RESET}"
    return 1
  fi

  echo "Будут разрешены адреса: ${allowed_ips[*]}"
  read -rp "Применить ограничение доступа к ISPmanager? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена."
    return 0
  fi

  firewall_backup=$(backup_firewall_rules) || {
    echo -e "${RED}Не удалось создать резервную копию правил. Изменения отменены.${RESET}"
    return 1
  }
  echo "Резервная копия фаервола: $firewall_backup"

  # Используем отдельную цепочку, чтобы повторный запуск заменял только правила,
  # созданные этим скриптом, и не затрагивал остальную конфигурацию INPUT.
  if ! sudo iptables -w 5 -nL "$chain_name" >/dev/null 2>&1; then
    sudo iptables -w 5 -N "$chain_name" || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  fi

  sudo iptables -w 5 -F "$chain_name" || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }

  # Сначала устанавливаем запрет по умолчанию. Это не оставляет порт открытым,
  # даже если добавление одного из разрешающих правил завершится ошибкой.
  sudo iptables -w 5 -A "$chain_name" -j DROP || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }

  for allowed_ip in "${allowed_ips[@]}"; do
    sudo iptables -w 5 -I "$chain_name" 1 -s "$allowed_ip/32" -j ACCEPT || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  done

  # Удаляем прежние переходы в управляемую цепочку, чтобы не создавать дубликаты.
  while sudo iptables -w 5 -C INPUT -p tcp --dport 1500 -j "$chain_name" >/dev/null 2>&1; do
    sudo iptables -w 5 -D INPUT -p tcp --dport 1500 -j "$chain_name" || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  done

  sudo iptables -w 5 -I INPUT 1 -p tcp --dport 1500 -j "$chain_name" || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }

  # Разрешённые адреса вводятся в формате IPv4. Чтобы порт не оставался
  # доступным в обход allowlist, полностью закрываем его по IPv6.
  if ! sudo ip6tables -w 5 -nL "$chain6_name" >/dev/null 2>&1; then
    sudo ip6tables -w 5 -N "$chain6_name" || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  fi
  sudo ip6tables -w 5 -F "$chain6_name" || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }
  sudo ip6tables -w 5 -A "$chain6_name" -j DROP || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }
  while sudo ip6tables -w 5 -C INPUT -p tcp --dport 1500 -j "$chain6_name" >/dev/null 2>&1; do
    sudo ip6tables -w 5 -D INPUT -p tcp --dport 1500 -j "$chain6_name" || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  done
  sudo ip6tables -w 5 -I INPUT 1 -p tcp --dport 1500 -j "$chain6_name" || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }

  # Сохраняем правила и включаем их автоматическое восстановление после загрузки.
  # Службу здесь не перезапускаем, чтобы не рисковать текущим SSH-подключением.
  if ! setup_iptables_persistence; then
    echo -e "${RED}Не удалось сохранить правила. Выполняем откат активного фаервола.${RESET}"
    restore_firewall_rules "$firewall_backup"
    return 1
  fi

  echo -e "${GREEN}Доступ к ISPmanager ограничен.${RESET}"
  sudo iptables -w 5 -L INPUT -n -v --line-numbers | grep -E "Chain|1500|$chain_name" || true
  sudo iptables -w 5 -L "$chain_name" -n -v --line-numbers
  sudo ip6tables -w 5 -L "$chain6_name" -n -v --line-numbers
  echo "Проверьте доступ с разрешённого IP до завершения текущей SSH-сессии."
}

list_ispmanager_access() {
  local chain_name="ISPMGR_ACCESS"
  local chain6_name="ISPMGR6_ACCESS"

  echo -e "${CYAN}=== Доступ к ISPmanager ===${RESET}"

  if sudo iptables -w 5 -nL "$chain_name" >/dev/null 2>&1; then
    echo "Управляемая цепочка $chain_name:"
    sudo iptables -w 5 -L "$chain_name" -n -v --line-numbers
  else
    echo "Управляемая цепочка $chain_name пока не создана."
  fi

  echo
  echo "Прямые правила INPUT для TCP-порта 1500:"
  if ! sudo iptables -w 5 -S INPUT | grep -E -- '--dport 1500'; then
    echo "Прямые правила отсутствуют."
  fi

  echo
  echo "Ограничение IPv6 для TCP-порта 1500:"
  if sudo ip6tables -w 5 -nL "$chain6_name" >/dev/null 2>&1; then
    sudo ip6tables -w 5 -L "$chain6_name" -n -v --line-numbers
  else
    echo -e "${YELLOW}Управляемая IPv6-цепочка отсутствует.${RESET}"
  fi
}

add_ispmanager_allowed_ip() {
  local chain_name="ISPMGR_ACCESS"
  local detected_ip=""
  local allowed_ip
  local confirmation
  local firewall_backup

  if ! sudo iptables -w 5 -nL "$chain_name" >/dev/null 2>&1; then
    echo -e "${RED}Сначала создайте ограничение через пункт 2 меню iptables.${RESET}"
    return 1
  fi

  if [[ -n "${SSH_CLIENT:-}" ]]; then
    detected_ip="${SSH_CLIENT%% *}"
  fi

  read -rp "Введите разрешённый IPv4-адрес${detected_ip:+ [по умолчанию: $detected_ip]}: " allowed_ip
  if [[ -z "$allowed_ip" && -n "$detected_ip" ]]; then
    allowed_ip="$detected_ip"
  fi

  if ! is_valid_ipv4 "$allowed_ip"; then
    echo -e "${RED}Некорректный IPv4-адрес: $allowed_ip.${RESET}"
    return 1
  fi

  if sudo iptables -w 5 -C "$chain_name" -s "$allowed_ip/32" -j ACCEPT >/dev/null 2>&1; then
    echo "Адрес $allowed_ip уже присутствует в управляемом allowlist."
    return 0
  fi

  read -rp "Разрешить доступ к ISPmanager с $allowed_ip? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена."
    return 0
  fi

  firewall_backup=$(backup_firewall_rules) || {
    echo -e "${RED}Не удалось создать резервную копию правил. Изменения отменены.${RESET}"
    return 1
  }
  echo "Резервная копия фаервола: $firewall_backup"

  # Разрешающее правило вставляется перед завершающим DROP.
  sudo iptables -w 5 -I "$chain_name" 1 -s "$allowed_ip/32" -j ACCEPT || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }

  if ! setup_iptables_persistence; then
    echo -e "${RED}Не удалось сохранить правила. Отменяем добавление адреса.${RESET}"
    restore_firewall_rules "$firewall_backup"
    return 1
  fi

  echo -e "${GREEN}Доступ с $allowed_ip разрешён.${RESET}"
  list_ispmanager_access
}

remove_ispmanager_allowed_ip() {
  local chain_name="ISPMGR_ACCESS"
  local allowed_ip
  local confirmation
  local managed_rule_exists=0
  local legacy_rule_exists=0
  local managed_rule_count=0
  local firewall_backup

  list_ispmanager_access
  echo
  read -rp "Введите IPv4-адрес, доступ которого нужно удалить: " allowed_ip

  if ! is_valid_ipv4 "$allowed_ip"; then
    echo -e "${RED}Некорректный IPv4-адрес: $allowed_ip.${RESET}"
    return 1
  fi

  if sudo iptables -w 5 -nL "$chain_name" >/dev/null 2>&1; then
    managed_rule_count=$(sudo iptables -w 5 -S "$chain_name" |
      grep -c -- '-j ACCEPT' || true)

    if sudo iptables -w 5 -C "$chain_name" -s "$allowed_ip/32" -j ACCEPT >/dev/null 2>&1; then
      managed_rule_exists=1
    fi
  fi

  # Поддерживаем удаление старых правил, созданных до появления ISPMGR_ACCESS.
  if sudo iptables -w 5 -C INPUT -s "$allowed_ip/32" -p tcp --dport 1500 -j ACCEPT >/dev/null 2>&1; then
    legacy_rule_exists=1
  fi

  if ((managed_rule_exists == 0 && legacy_rule_exists == 0)); then
    echo "Разрешающие правила для $allowed_ip не найдены."
    return 0
  fi

  if ((managed_rule_exists == 1 && managed_rule_count <= 1)); then
    echo -e "${RED}Нельзя удалить последний адрес из управляемого allowlist.${RESET}"
    echo "Сначала добавьте новый разрешённый IP."
    return 1
  fi

  read -rp "Удалить доступ к ISPmanager для $allowed_ip? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена."
    return 0
  fi

  firewall_backup=$(backup_firewall_rules) || {
    echo -e "${RED}Не удалось создать резервную копию правил. Изменения отменены.${RESET}"
    return 1
  }
  echo "Резервная копия фаервола: $firewall_backup"

  while sudo iptables -w 5 -C "$chain_name" -s "$allowed_ip/32" -j ACCEPT >/dev/null 2>&1; do
    sudo iptables -w 5 -D "$chain_name" -s "$allowed_ip/32" -j ACCEPT || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  done

  while sudo iptables -w 5 -C INPUT -s "$allowed_ip/32" -p tcp --dport 1500 -j ACCEPT >/dev/null 2>&1; do
    sudo iptables -w 5 -D INPUT -s "$allowed_ip/32" -p tcp --dport 1500 -j ACCEPT || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  done

  if ! setup_iptables_persistence; then
    echo -e "${RED}Не удалось сохранить правила. Отменяем удаление адреса.${RESET}"
    restore_firewall_rules "$firewall_backup"
    return 1
  fi

  echo -e "${GREEN}Доступ для $allowed_ip удалён.${RESET}"
  list_ispmanager_access
}

# Подменю iptables
iptables_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Фаервол iptables ===${RESET}"
    echo "1. Список правил iptables"
    echo "2. Ограничить доступ к ISPmanager по IP"
    echo "3. Показать доступ к ISPmanager"
    echo "4. Добавить разрешённый IP для ISPmanager"
    echo "5. Удалить разрешённый IP для ISPmanager"
    echo "6. Проверить сохранение правил после перезагрузки"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) rules_iptables ;;
    2) restrict_ispmanager_access ;;
    3) list_ispmanager_access ;;
    4) add_ispmanager_allowed_ip ;;
    5) remove_ispmanager_allowed_ip ;;
    6) check_iptables_persistence ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Главное меню
while true; do
  echo
  echo "=== Главное меню ==="
  echo "1. Система"
  echo "2. SSH"
  echo "3. Fail2Ban"
  echo "4. Пользователи"
  echo "5. Nginx"
  echo "6. Сеть"
  echo "7. Фаервол iptables"
  echo "8. Аудит безопасности без изменений"
  echo "9. Автоматические обновления безопасности"
  echo "10. Инвентаризация и отключение служб"
  echo "11. Проверка файловой системы"
  echo "12. Сохранить итоговый отчёт безопасности"
  echo "0. Выход"
  echo
  read -p "Введите номер раздела: " MAIN_CHOICE

  case $MAIN_CHOICE in
  1) system_menu ;;
  2) ssh_settings_menu ;;
  3) fail2ban_settings_menu ;;
  4) user_settings_menu ;;
  5) nginx_menu ;;
  6) network_menu ;;
  7) iptables_menu ;;
  8) security_audit ;;
  9) security_updates_menu ;;
  10) services_security_menu ;;
  11) filesystem_security_audit ;;
  12) save_security_report ;;
  0)
    echo "Выход."
    exit 0
    ;;
  *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
  esac
done
