#!/bin/bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m' # Reset to default color

######### SSH Settings ########

check_ssh_settings() {
  echo -e "${CYAN}==================== Проверяем текущие SSH настройки ====================${RESET}"
  echo -e "${GREEN}Выполняю: grep PubkeyAuthentication /etc/ssh/sshd_config && grep PasswordAuthentication /etc/ssh/sshd_config ${RESET}"
  grep PubkeyAuthentication /etc/ssh/sshd_config && grep PasswordAuthentication /etc/ssh/sshd_config
}

block_ssh_access_by_password() {
  echo -e "${CYAN}==================== Блокируем доступ к SSH по паролю ====================${RESET}"

  sudo sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^#PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^#PasswordAuthentication no/PasswordAuthentication no/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config &&
  restart_ssh && check_ssh_settings
}

open_ssh_access_by_password() {
  echo -e "${CYAN}==================== Открываем доступ к SSH по паролю ====================${RESET}"

  sudo sed -i 's/^#PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
  sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
  restart_ssh && check_ssh_settings
}

check_ssh_connection_by_password() {
  echo -e "${CYAN}==================== Пробуем подключится к SSH по паролю ====================${RESET}"

  if ! ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@localhost; then
    echo "✅ Проверка пройдена: подключение по паролю не удалось, как и должно быть."
  else
    echo "⚠️ Осторожно: подключение по паролю УДАЛОСЬ!"
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

######### User ########

create_new_user() {
  echo "Создание нового пользователя..."
  read -p "Введите имя пользователя: " USERNAME
  echo "sudo adduser $USERNAME"
  sudo adduser "$USERNAME"
}

######### fail2ban  ########

# основной конфиг /etc/fail2ban/jail.conf
# дополнительный локальный конфиг /etc/fail2ban/jail.local

JAIL_LOCAL="/etc/fail2ban/jail.local"
NGINX_FILTER="/etc/fail2ban/filter.d/nginx-badbots.conf"
NGINX_ACCESS_LOG="/var/log/nginx/access.log"

install_fail2ban() {
  echo -e "${CYAN}========== Устанавливаем Fail2ban... ==========${RESET}"
  echo -e "${GREEN}Выполняю: sudo apt update && sudo apt install -y fail2ban ${RESET}"
  sudo apt update && sudo apt install -y fail2ban &&
  echo "Fail2ban установлен." &&
  check_status_fail2ban
}

fail2ban_configure_nginx() {
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

[nginx-badbots]
enabled = true
filter = nginx-badbots
action = iptables[name=NGINX-BADBOTS, port=http, protocol=tcp]
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

fail2ban_configure_ssh() {
  echo -e "${CYAN}========== Настраиваем Fail2ban для ssh.. ==========${RESET}"

  if ! grep -q "\[sshd\]" "$JAIL_LOCAL"; then
    sudo tee -a "$JAIL_LOCAL" >/dev/null <<EOF

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF
    echo "Конфигурация ssh добавлена в $JAIL_LOCAL"
  else
    echo "Конфигурация ssh уже существует в $JAIL_LOCAL"
  fi

  sudo systemctl restart fail2ban
}

check_status_fail2ban() {
  echo -e "${CYAN}========== Проверяем статус Fail2ban ==========${RESET}"
  echo -e "${GREEN}Выполняю: sudo systemctl status fail2ban ${RESET}"
  sudo systemctl status fail2ban
}

check_status_fail2ban_nginx() {
  echo -e "${CYAN}========== Проверяем статус Fail2ban nginx ==========${RESET}"
  echo -e "${GREEN}Выполняю: sudo fail2ban-client status nginx-badbots ${RESET}"
  sudo fail2ban-client status nginx-badbots
}

check_status_fail2ban_ssh() {
  echo -e "${CYAN}========== Проверяем статус Fail2ban ssh ==========${RESET}"
  echo -e "${GREEN}Выполняю: sudo fail2ban-client status sshd ${RESET}"
  sudo fail2ban-client status sshd
}

fail2ban_log() {
  echo -e "${CYAN}========== Читаем логи Fail2ban ==========${RESET}"
  echo -e "${GREEN}Выполняю: sudo tail -n 100 -f /var/log/fail2ban.log ${RESET}"
  sudo tail -n 100 -f /var/log/fail2ban.log
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
    echo -e "${CYAN}=== Fail2ban menu ===${RESET}"
    echo "1. Установить Fail2ban"
    echo "2. Статус Fail2ban"
    echo "3. Сконфигурировать Fail2ban для nginx"
    echo "4. Сконфигурировать Fail2ban для ssh"
    echo "5. Статус Fail2ban client для nginx"
    echo "6. Статус Fail2ban client для ssh"
    echo "7. Читать лог Fail2ban"
    echo "0. Назад в главное меню"
    read -rp "Выберите действие [1-4]: " CHOICE

    case $CHOICE in
    1) install_fail2ban ;;
    2) check_status_fail2ban ;;
    3) fail2ban_configure_nginx ;;
    4) fail2ban_configure_ssh ;;
    5) check_status_fail2ban_nginx ;;
    6) check_status_fail2ban_ssh ;;
    7) fail2ban_log ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
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
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) check_ssh_settings ;;
    2) block_ssh_access_by_password ;;
    3) open_ssh_access_by_password ;;
    4) check_ssh_connection_by_password ;;
    5) check_status_fail2ban_nginx ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

rules_iptables() {
  echo -e "${GREEN}Выполняю: sudo iptables -L -n --line-numbers ${RESET}"
  sudo iptables -L -n --line-numbers
}

# Подменю iptables
iptables_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== SSH menu ===${RESET}"
    echo "1. Список правил iptables"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) rules_iptables ;;
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
