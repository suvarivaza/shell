#!/bin/bash


prompt_log_file() {
    read -p "Введите путь до файла access.log: " ACCESS_LOG_FILE
    if [[ ! -f $ACCESS_LOG_FILE ]]; then
        echo "Файл $$ACCESS_LOG_FILE не найден! Убедитесь, что путь указан правильно."
        exit 1
    fi
}

find_access_log(){
  sudo find / -type f -name "*access.log" 2>/dev/null
}

read_access_log() {
    tail -f -n 100 $ACCESS_LOG_FILE
}

install_goaccess() {
    sudo apt update &&
    sudo apt install goaccess &&
    uncomment_goaccess_config
}


uncomment_goaccess_config() {
  local conf="/etc/goaccess/goaccess.conf"

  sudo sed -i 's|^#time-format %H:%M:%S|time-format %H:%M:%S|' $conf &&
  sudo sed -i 's|^#date-format %d/%b/%Y|date-format %d/%b/%Y|' $conf &&
  sudo sed -i 's|^#log-format %h %\[%d:%t %\] "%r" %s %b "%R" "%u"|log-format %h %\[%d:%t %\] "%r" %s %b "%R" "%u"|' $conf

  if [ $? -eq 0 ]; then
    echo "GoAccess config successfully updated."
  else
    echo "Failed to update GoAccess config $conf" >&2
  fi
}


run_goaccess() {
    sudo goaccess $ACCESS_LOG_FILE
}

while true; do
    echo
    echo "Выберите действие:"
    echo "1. Найти access.log"
    echo "2. Читать access.log"
    echo "3. Установить goaccess"
    echo "4. Запустить goaccess"
    echo "0. Выход"
    read -p "Введите номер действия: " CHOICE

    case $CHOICE in
        1) find_access_log ;;
        2) [[ -z "$ACCESS_LOG_FILE" ]] && prompt_log_file; read_access_log ;;
        3) [[ -z "$ACCESS_LOG_FILE" ]] && prompt_log_file; install_goaccess ;;
        4) run_goaccess ;;
        0) echo "Выход."; exit 0 ;;
        *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
done