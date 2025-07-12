#!/bin/bash


function prompt_log_file() {
    read -p "Введите путь до файла access.log: " ACCESS_LOG_FILE
    if [[ ! -f $ACCESS_LOG_FILE ]]; then
        echo "Файл $$ACCESS_LOG_FILE не найден! Убедитесь, что путь указан правильно."
        exit 1
    fi
}

function find_access_log(){
  sudo find / -type f -name "*access.log" 2>/dev/null
}

function read_access_log() {
    tail -f -n 100 $ACCESS_LOG_FILE
}

function install_goaccess() {
    sudo apt update &&
    sudo apt install goaccess &&
    echo "Отредактируйте конфиг: vi /etc/goaccess/goaccess.conf (раскомментируй строки: time-format date-format log-format) после этого можно запускать goaccess"
}

function run_goaccess() {
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