#!/bin/bash

block_access_by_password() {
  sudo sed -i 's/^#PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config &&
    sudo sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config &&
    sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config &&
    sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config &&
    restart_ssh
}

restart_ssh() {
  if grep -qi "ubuntu" /etc/os-release; then
    #      echo "Detected Ubuntu, restarting SSH..."
    sudo systemctl restart ssh
  elif grep -qi "centos" /etc/os-release; then
    #      echo "Detected CentOS, restarting SSH..."
    sudo systemctl restart sshd
  else
    echo "Unknown OS, SSH restart command not executed."
  fi
}

# Меню
while true; do
  echo
  echo "Выберите действие:"
  echo "1. Заблокировать доступ по паролю"
  echo "0. Выход"
  echo
  read -p "Введите номер действия: " CHOICE

  case $CHOICE in
  1) block_access_by_password ;;
  0)
    echo "Выход."
    exit 0
    ;;
  *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
  esac
done
