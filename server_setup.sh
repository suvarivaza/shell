#!/bin/bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'  # Reset to default color




######### SSH Settings ########

check_ssh_settings(){
  echo -e "${CYAN}==================== Проверяем текущие SSH настройки ====================${RESET}"
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

check_ssh_connection_by_password(){
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

create_new_user() {
  echo "Создание нового пользователя..."
  read -p "Введите имя пользователя: " USERNAME
  sudo adduser "$USERNAME"
}


######### fail2ban ########

JAIL_LOCAL="/etc/fail2ban/jail.local"
NGINX_FILTER="/etc/fail2ban/filter.d/nginx-badbots.conf"

function install_fail2ban() {
    echo -e "${CYAN}========== Устанавливаем Fail2ban... ==========${RESET}"
    sudo apt update
    sudo apt install -y fail2ban
    echo "Fail2ban установлен."
}

function fail2ban_configure_nginx() {
    echo -e "${CYAN}========== Настраиваем Fail2ban для nginx.. ==========${RESET}"

    # Создание фильтра
    sudo tee "$NGINX_FILTER" > /dev/null <<EOF
[Definition]
failregex = <HOST> -.*"(GET|POST).*"(wp-login\\.php|admin|xmlrpc\\.php|\\.env|\\.git|\\.bash_history)
ignoreregex =
EOF

    # Добавление в jail.local
    if ! grep -q "\[nginx-badbots\]" "$JAIL_LOCAL"; then
        sudo tee -a "$JAIL_LOCAL" > /dev/null <<EOF

[nginx-badbots]
enabled = true
filter = nginx-badbots
action = iptables[name=NGINX-BADBOTS, port=http, protocol=tcp]
logpath = /var/log/nginx/access.log
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

function fail2ban_configure_ssh() {
    echo -e "${CYAN}========== Настраиваем Fail2ban для ssh.. ==========${RESET}"

    if ! grep -q "\[sshd\]" "$JAIL_LOCAL"; then
        sudo tee -a "$JAIL_LOCAL" > /dev/null <<EOF

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

fail2ban_settings_menu() {
  while true; do
      echo ""
      echo -e "${CYAN}=== Fail2ban Settings ===${RESET}"
      echo "1) Установить Fail2ban"
      echo "2) Сконфигурировать Fail2ban для nginx"
      echo "3) Сконфигурировать Fail2ban для ssh"
      echo "4) Выход"
      read -rp "Выберите действие [1-4]: " CHOICE

      case $CHOICE in
          1) install_fail2ban ;;
          2) fail2ban_configure_nginx ;;
          3) fail2ban_configure_ssh ;;
          0) break ;;
          *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
      esac
  done
}



# Подменю SSH
ssh_settings_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== SSH Settings ===${RESET}"
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
      0) break ;;
      *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю Users
user_settings_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== User Settings ===${RESET}"
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

# Главное меню
while true; do
  echo
  echo "=== Главное меню ==="
  echo "1. SSH Settings"
  echo "2. fail2ban Settings"
  echo "3. User Settings"
  echo "0. Выход"
  echo
  read -p "Введите номер раздела: " MAIN_CHOICE

  case $MAIN_CHOICE in
    1) ssh_settings_menu ;;
    2) fail2ban_settings_menu ;;
    3) user_settings_menu ;;
    0)
      echo "Выход."
      exit 0
      ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
  esac
done

# Меню
#while true; do
#  echo
#  echo "Выберите действие:"
#  echo "1. Проверить SSH настройки"
#  echo "2. Заблокировать доступ к SSH по паролю"
#  echo "3. Открыть доступ к SSH по паролю"
#  echo "4. Попробовать подключится к SSH по паролю"
#  echo "0. Выход"
#  echo
#  read -p "Введите номер действия: " CHOICE
#
#  case $CHOICE in
#  1) check_ssh_settings ;;
#  2) block_ssh_access_by_password ;;
#  3) open_ssh_access_by_password ;;
#  4) check_ssh_connection_by_password ;;
#  0)
#    echo "Выход."
#    exit 0
#    ;;
#  *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
#  esac
#done
