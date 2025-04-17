#!/bin/bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'  # Reset to default color


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

# Меню
while true; do
  echo
  echo "Выберите действие:"
  echo "1. Проверить SSH настройки"
  echo "2. Заблокировать доступ к SSH по паролю"
  echo "3. Открыть доступ к SSH по паролю"
  echo "4. Попробовать подключится к SSH по паролю"
  echo "0. Выход"
  echo
  read -p "Введите номер действия: " CHOICE

  case $CHOICE in
  1) check_ssh_settings ;;
  2) block_ssh_access_by_password ;;
  3) open_ssh_access_by_password ;;
  4) check_ssh_connection_by_password ;;
  0)
    echo "Выход."
    exit 0
    ;;
  *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
  esac
done
