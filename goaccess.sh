#!/bin/bash

prompt_log_file() {
    read -p "Введите путь до файла access.log: " ACCESS_LOG_FILE
    if [[ ! -f $ACCESS_LOG_FILE ]]; then
        echo "Файл $$ACCESS_LOG_FILE не найден! Убедитесь, что путь указан правильно."
        exit 1
    fi
}

install_goaccess() {
    sudo apt update &&
    sudo apt install goaccess &&
    uncomment_goaccess_config
}


uncomment_goaccess_config() {
  local conf="/etc/goaccess/goaccess.conf"


#раскоментируем 3 строки:
#time-format %H:%M:%S
#date-format %d/%b/%Y
#log-format %h %^[%d:%t %^] "%r" %s %b "%R" "%u"


  sudo sed -i 's|^#time-format %H:%M:%S|time-format %H:%M:%S|' $conf &&
  sudo sed -i 's|^#date-format %d/%b/%Y|date-format %d/%b/%Y|' $conf &&
  sudo sed -i 's|^#log-format %h %\^\[%d:%t %\^] "%r" %s %b "%R" "%u"|log-format %h %^[%d:%t %^] "%r" %s %b "%R" "%u"|' "$conf"


  if [ $? -eq 0 ]; then
    echo "GoAccess config successfully updated."
  else
    echo "Failed to update GoAccess config $conf" >&2
  fi
}


run_goaccess() {
    sudo goaccess $ACCESS_LOG_FILE -p /etc/goaccess/goaccess.conf
}

while true; do
    echo
    echo "Выберите действие:"
    echo "1. Установить goaccess"
    echo "2. Запустить goaccess"
    echo "0. Выход"
    read -p "Введите номер действия: " CHOICE

    case $CHOICE in
        1) [[ -z "$ACCESS_LOG_FILE" ]] && prompt_log_file; install_goaccess ;;
        2) [[ -z "$ACCESS_LOG_FILE" ]] && prompt_log_file; run_goaccess ;;
        0) echo "Выход."; exit 0 ;;
        *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
done