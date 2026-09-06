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


#need to uncomment 3 string in config:
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
    echo "Menu:"
    echo "1. Install goaccess"
    echo "2. Run goaccess"
    echo "0. Exit"
    read -p "Enter the action number: " CHOICE

    case $CHOICE in
        1) [[ -z "$ACCESS_LOG_FILE" ]] && prompt_log_file; install_goaccess ;;
        2) [[ -z "$ACCESS_LOG_FILE" ]] && prompt_log_file; run_goaccess ;;
        0) echo "Exit."; exit 0 ;;
        *) echo "Wrong number. Please try again.." ;;
    esac
done