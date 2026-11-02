#!/bin/bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m' # Reset to default color

######### SSH Settings OLD ########

check_ssh_settings_old() {
  echo -e "${CYAN}==================== Проверяем текущие SSH настройки ====================${RESET}"
  echo -e "${GREEN}Выполняю: grep PubkeyAuthentication /etc/ssh/sshd_config && grep PasswordAuthentication /etc/ssh/sshd_config ${RESET}"
  grep PubkeyAuthentication /etc/ssh/sshd_config && grep PasswordAuthentication /etc/ssh/sshd_config
}

block_ssh_access_by_password_old() {
  echo -e "${CYAN}==================== Блокируем доступ к SSH по паролю ====================${RESET}"

  sudo sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^#PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^#PasswordAuthentication no/PasswordAuthentication no/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config &&
  restart_ssh && check_ssh_settings
}

open_ssh_access_by_password_old() {
  echo -e "${CYAN}==================== Открываем доступ к SSH по паролю ====================${RESET}"

  sudo sed -i 's/^#PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
  restart_ssh && check_ssh_settings
}

check_ssh_connection_by_password_old() {
  echo -e "${CYAN}==================== Пробуем подключится к SSH по паролю ====================${RESET}"

  if ! ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@localhost; then
    echo "✅ Проверка пройдена: подключение по паролю не удалось, как и должно быть."
  else
    echo "⚠️ Осторожно: подключение по паролю УДАЛОСЬ!"
  fi

}

######### SSH Settings ########


check_ssh_settings() {
  echo -e "${CYAN}==== Эффективные настройки SSH ====${RESET}"
  sudo sshd -T | grep -E 'passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication'
}

block_ssh_access_by_password() {
  echo -e "${CYAN}==== Блокируем доступ к SSH по паролю ====${RESET}"

  sudo tee /etc/ssh/sshd_config.d/99-custom.conf > /dev/null <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF

  restart_ssh
  check_ssh_settings
}


open_ssh_access_by_password() {
  echo -e "${CYAN}==== Разрешаем доступ к SSH по паролю ====${RESET}"

  sudo tee /etc/ssh/sshd_config.d/99-custom.conf > /dev/null <<EOF
PubkeyAuthentication yes
PasswordAuthentication yes
EOF

  restart_ssh
  check_ssh_settings
}

check_ssh_connection_by_password() {
  echo -e "${CYAN}==== Проверка входа по паролю ====${RESET}"

  if ssh -o PreferredAuthentications=password \
         -o PubkeyAuthentication=no \
         -o ConnectTimeout=5 \
         root@localhost exit 2>/dev/null; then

    echo "⚠️ Пароль РАБОТАЕТ — это проблема"
  else
    echo "✅ Пароль отключен"
  fi
}

restart_ssh() {
  if grep -qi "ubuntu" /etc/os-release; then
    #      echo "Detected Ubuntu, restarting SSH..."
    sudo systemctl restart ssh && echo "OK! service ssh restarted"
  elif grep -qi "centos" /etc/os-release; then
    #      echo "Detected CentOS, restarting SSH..."
    sudo systemctl restart sshd && echo "OK! service sshd restarted"
  else
    echo "Unknown OS, SSH restart command not executed."
  fi
}

find_ssh_configs(){
  grep -R "PasswordAuthentication" /etc/ssh/
}

######### User ########

create_new_user() {
  echo "Создание нового пользователя..."
  read -p "Введите имя пользователя: " USERNAME
  echo "sudo adduser $USERNAME"
  sudo adduser "$USERNAME"
}

######### fail2ban OLD  ########

# основной конфиг /etc/fail2ban/jail.conf
# дополнительный локальный конфиг /etc/fail2ban/jail.local
# sudo iptables -L -n --line-numbers #показать все правила iptables.
# iptables -D INPUT 7 #удалить правило в строке 7

JAIL_LOCAL="/etc/fail2ban/jail.local"
NGINX_FILTER="/etc/fail2ban/filter.d/nginx-badbots.conf"
NGINX_ACCESS_LOG="/var/log/nginx/access.log"

install_fail2ban_old() {
  echo -e "${CYAN}========== Устанавливаем Fail2ban... ==========${RESET}"
  echo -e "${GREEN}Выполняю: sudo apt update && sudo apt install -y fail2ban ${RESET}"
  sudo apt update && sudo apt install -y fail2ban &&
  echo "Fail2ban установлен." &&
  check_status_fail2ban
}

fail2ban_configure_nginx_old() {
  echo -e "${CYAN}========== Проверяем статус Fail2ban client для nginx.. ==========${RESET}"

  # Создание фильтра
  sudo tee "$NGINX_FILTER" >/dev/null <<EOF
[Definition]
failregex = <HOST> -.*"(GET|POST).*"(wp-login\\.php|admin|xmlrpc\\.php|\\.env|\\.git|\\.bash_history)
ignoreregex =
EOF

  # Добавление в jail.local
  if ! grep -q "\[nginx-badbots\]" "$JAIL_LOCAL"; then
    sudo tee -a "$JAIL_LOCAL" >/dev/null <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 5
backend = auto
[nginx-badbots]
enabled = true
filter = nginx-badbots
action = %(action_)s
logpath = $NGINX_ACCESS_LOG
maxretry = 1
bantime = 86400
findtime = 600
EOF
    echo "Конфигурация nginx добавлена в $JAIL_LOCAL"
  else
    echo "Конфигурация nginx уже существует в $JAIL_LOCAL"
  fi

  sudo systemctl restart fail2ban
}

fail2ban_configure_ssh_old() {
  echo -e "${CYAN}========== Настраиваем Fail2ban для ssh.. ==========${RESET}"

  if ! grep -q "\[sshd\]" "$JAIL_LOCAL"; then
    sudo tee -a "$JAIL_LOCAL" >/dev/null <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = %(sshd_log)s
backend = systemd
maxretry = 3
bantime = 1h
findtime = 10m
EOF
    echo "Конфигурация ssh добавлена в $JAIL_LOCAL"
  else
    echo "Конфигурация ssh уже существует в $JAIL_LOCAL"
  fi

  sudo systemctl restart fail2ban
}

check_status_fail2ban_old() {
  echo -e "${CYAN}========== Проверяем статус Fail2ban ==========${RESET}"
  echo -e "${GREEN}Выполняю: sudo systemctl status fail2ban ${RESET}"
  sudo systemctl status fail2ban
}

check_status_fail2ban_nginx_old() {
  echo -e "${CYAN}========== Проверяем статус Fail2ban nginx ==========${RESET}"
  echo -e "${GREEN}Выполняю: sudo fail2ban-client status nginx-badbots ${RESET}"
  sudo fail2ban-client status nginx-badbots
}

check_status_fail2ban_ssh_old() {
  echo -e "${CYAN}========== Проверяем статус Fail2ban ssh ==========${RESET}"
  echo -e "${GREEN}Выполняю: sudo fail2ban-client status sshd ${RESET}"
  sudo fail2ban-client status sshd
}

fail2ban_log_old() {
  echo -e "${CYAN}========== Читаем логи Fail2ban ==========${RESET}"
  echo -e "${GREEN}Выполняю: sudo tail -n 100 -f /var/log/fail2ban.log ${RESET}"
  sudo tail -n 100 -f /var/log/fail2ban.log
}



# Fail2ban menu + setup (refined)

JAIL_LOCAL="/etc/fail2ban/jail.local"
NGINX_ACCESS_LOG="/var/log/nginx/access.log"

install_fail2ban() {
  echo "Installing Fail2ban..."
  sudo apt update && sudo apt install -y fail2ban
  sudo systemctl enable fail2ban
  sudo systemctl start fail2ban
}

setup_fail2ban_base() {
  echo "Configuring fail2ban (safe mode)..."

  sudo mkdir -p /etc/fail2ban/jail.d

  sudo tee /etc/fail2ban/jail.d/custom.conf >/dev/null <<EOF
[nginx-botsearch]
enabled = true
logpath = $NGINX_ACCESS_LOG

[nginx-noscript]
enabled = true
logpath = $NGINX_ACCESS_LOG
EOF

  sudo systemctl restart fail2ban
}

check_fail2ban() {
  echo "Fail2ban overall status:"
  sudo fail2ban-client status
}

check_jail() {
  echo "Available jails:"
  sudo fail2ban-client status
  echo ""
  read -rp "Enter jail name (e.g. sshd): " jail
  sudo fail2ban-client status "$jail"
}

fail2ban_log() {
  sudo tail -f /var/log/fail2ban.log
}



######### system  ########

system_info() {
  echo -e "${GREEN}Выполняю: cat /etc/os-release ${RESET}"
  cat /etc/os-release
  echo -e "${GREEN}Выполняю: hostnamectl ${RESET}"
  hostnamectl
}

all_services() {
  echo -e "${GREEN}Выполняю: systemctl list-units --type=service ${RESET}"
  systemctl list-units --type=service
}

system_log() {
  echo -e "${GREEN}Выполняю: tail -n 100 -f /var/log/syslog ${RESET}"
  tail -n 100 -f /var/log/syslog
}

######### nginx  ########

nginx_status() {
  echo -e "${GREEN}Выполняю: systemctl status nginx ${RESET}"
  systemctl status nginx
}

nginx_reload() {
  echo -e "${GREEN}Выполняю: systemctl reload nginx ${RESET}"
  systemctl reload nginx
}

######### Networks  ########

open_ports() {
  echo -e "${GREEN}Выполняю: netstat -tnlp ${RESET}"
  netstat -tnlp
}

# Подменю nginx
nginx_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Nginx menu ===${RESET}"
    echo "1. Nginx status"
    echo "2. Nginx reload"
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
    echo -e "${CYAN}=== System menu ===${RESET}"
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

# Подменю Users
user_settings_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== User menu ===${RESET}"
    echo "1. Создать нового пользователя"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) create_new_user ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю Users
network_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Network menu ===${RESET}"
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
    echo "=== Fail2ban menu ==="
    echo "1. Install Fail2ban"
    echo "2. Status (all)"
    echo "3. Status (specific jail)"
    echo "4. Setup (nginx + ssh)"
    echo "5. View logs"
    echo "0. Back"

    read -rp "Choose [0-5]: " CHOICE

    case $CHOICE in
      1) install_fail2ban ;;
      2) check_fail2ban ;;
      3) check_jail ;;
      4) setup_fail2ban_base ;;
      5) fail2ban_log ;;
      0) break ;;
      *) echo "Invalid option" ;;
    esac
  done
}

# Подменю SSH
ssh_settings_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== SSH menu ===${RESET}"
    echo "1. Проверить SSH настройки"
    echo "2. Заблокировать доступ к SSH по паролю"
    echo "3. Открыть доступ к SSH по паролю"
    echo "4. Попробовать подключиться к SSH по паролю"
    echo "5. Найти SSH конфиги"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) check_ssh_settings ;;
    2) block_ssh_access_by_password ;;
    3) open_ssh_access_by_password ;;
    4) check_ssh_connection_by_password ;;
    5) find_ssh_configs ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

rules_iptables() {
  echo -e "${GREEN}Выполняю: sudo iptables -L -n --line-numbers ${RESET}"
  sudo iptables -L -n --line-numbers
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

  echo -e "${GREEN}Правила сохранены через netfilter-persistent.${RESET}"
  echo "IPv4: /etc/iptables/rules.v4"
  echo "IPv6: /etc/iptables/rules.v6"

  if [[ -f /etc/iptables/ipsets ]]; then
    echo "IP-наборы: /etc/iptables/ipsets"
  fi

  echo "Служба включена в автозагрузку:"
  sudo systemctl is-enabled netfilter-persistent
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
  local detected_ip=""
  local allowed_ip_input
  local allowed_ip
  local confirmation
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

  # Используем отдельную цепочку, чтобы повторный запуск заменял только правила,
  # созданные этим скриптом, и не затрагивал остальную конфигурацию INPUT.
  if ! sudo iptables -nL "$chain_name" >/dev/null 2>&1; then
    sudo iptables -N "$chain_name" || return 1
  fi

  sudo iptables -F "$chain_name" || return 1

  # Сначала устанавливаем запрет по умолчанию. Это не оставляет порт открытым,
  # даже если добавление одного из разрешающих правил завершится ошибкой.
  sudo iptables -A "$chain_name" -j DROP || return 1

  for allowed_ip in "${allowed_ips[@]}"; do
    sudo iptables -I "$chain_name" 1 -s "$allowed_ip/32" -j ACCEPT || return 1
  done

  # Удаляем прежние переходы в управляемую цепочку, чтобы не создавать дубликаты.
  while sudo iptables -C INPUT -p tcp --dport 1500 -j "$chain_name" >/dev/null 2>&1; do
    sudo iptables -D INPUT -p tcp --dport 1500 -j "$chain_name" || return 1
  done

  sudo iptables -I INPUT 1 -p tcp --dport 1500 -j "$chain_name" || return 1

  # Сохраняем правила и включаем их автоматическое восстановление после загрузки.
  # Службу здесь не перезапускаем, чтобы не рисковать текущим SSH-подключением.
  if ! setup_iptables_persistence; then
    echo -e "${RED}Правила применены, но не удалось настроить их автоматическое восстановление.${RESET}"
    return 1
  fi

  echo -e "${GREEN}Доступ к ISPmanager ограничен.${RESET}"
  sudo iptables -L INPUT -n -v --line-numbers | grep -E "Chain|1500|$chain_name" || true
  sudo iptables -L "$chain_name" -n -v --line-numbers
  echo "Проверьте доступ с разрешённого IP до завершения текущей SSH-сессии."
}

# Подменю iptables
iptables_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Фаервол iptables ===${RESET}"
    echo "1. Список правил iptables"
    echo "2. Ограничить доступ к ISPmanager по IP"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) rules_iptables ;;
    2) restrict_ispmanager_access ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Главное меню
while true; do
  echo
  echo "=== Главное меню ==="
  echo "1. System"
  echo "2. SSH Settings"
  echo "3. Fil2ban Settings"
  echo "4. User Settings"
  echo "5. Nginx"
  echo "6. Network"
  echo "7. Фаервол iptables"
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
  0)
    echo "Выход."
    exit 0
    ;;
  *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
  esac
done
