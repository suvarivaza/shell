#!/bin/bash

# Путь до access.log
LOG_FILE=""

# Функции для анализа
prompt_log_file() {
    read -p "Введите путь до файла access.log: " LOG_FILE
    if [[ ! -f $LOG_FILE ]]; then
        echo "Файл $LOG_FILE не найден! Убедитесь, что путь указан правильно."
        exit 1
    fi
}

show_top_ips() {
    echo "Топ IP адресов по нагрузке:"
    awk '{print $1}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -n 10
}

show_top_urls() {
    echo "Топ URL, к которым происходит обращение:"
    awk '{print $7}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -n 10
}

show_top_user_agents() {
    echo "Топ User-Agent:"
    awk -F\" '{print $6}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -n 10
}

show_top_bots() {
    echo "Топ ботов, сканирующих сайт:"
    awk -F\" '{if ($6 ~ /bot|spider|crawler|crawl/i) print $6}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -n 10
}

show_server_load() {
    echo "Анализ процессов, нагружающих сервер:"
    ps -eo pid,user,%cpu,%mem,command --sort=-%cpu | head -n 10
}

show_server_stats() {
    echo "Статистика сервера:"
    echo "Загрузка процессора:"
    mpstat | grep "all"
    echo
    echo "Использование памяти:"
    free -h
    echo
    echo "Занятость дисков:"
    df -h
    echo
    echo "Средняя нагрузка на сервер:"
    uptime
    echo
    echo "Топ процессов по нагрузке:"
    ps -eo pid,user,%cpu,%mem,command --sort=-%cpu | head -n 10
}

analyze_database() {
    echo "Анализ работы базы данных:"
    echo
    echo "Подключенные пользователи и текущие запросы (MySQL):"
    echo "-------------------------------------------"
    mysql -e "SHOW FULL PROCESSLIST;" 2>/dev/null || echo "Не удалось подключиться к MySQL"
    echo
    echo "Самые медленные запросы (если включен slow log):"
    SLOW_LOG=$(mysql -e "SHOW VARIABLES LIKE 'slow_query_log_file';" 2>/dev/null | awk '{if (NR==2) print $2}')
    if [[ -f "$SLOW_LOG" ]]; then
        echo "-------------------------------------------"
        tail -n 20 "$SLOW_LOG"
    else
        echo "Slow log не включен или не найден."
    fi
}

detect_server_load_source() {
    echo "Определение источника нагрузки:"
    CPU_LOAD=$(awk '{print $1}' /proc/loadavg)
    echo "Текущая загрузка CPU: $CPU_LOAD"
    WEB_LOAD=$(awk '{print $1}' "$LOG_FILE" | wc -l)
    DB_LOAD=$(mysql -e "SHOW PROCESSLIST;" 2>/dev/null | wc -l || echo "0")
    echo "Обращений к веб-серверу (за период): $WEB_LOAD"
    echo "Обработанных запросов базой данных (в данный момент): $DB_LOAD"

    if [[ $CPU_LOAD > 4.0 ]]; then
        echo "Загрузка CPU высокая. Проверьте запущенные процессы."
    fi
    if [[ $WEB_LOAD -gt 1000 ]]; then
        echo "Веб-сервер под нагрузкой. Проверьте access.log."
    fi
    if [[ $DB_LOAD -gt 50 ]]; then
        echo "Высокая активность в базе данных."
    fi
}

# Меню
while true; do
    echo
    echo "Выберите действие:"
    echo "1. Указать путь до access.log"
    echo "2. Показать топ IP адресов по нагрузке"
    echo "3. Показать топ URL, к которым происходит обращение"
    echo "4. Показать топ User-Agent"
    echo "5. Показать топ ботов, сканирующих сайт"
    echo "6. Что нагружает сервер"
    echo "7. Статистика сервера"
    echo "8. Анализ базы данных (MySQL)"
    echo "9. Определить источник нагрузки"
    echo "10. Выход"
    echo
    read -p "Введите номер действия: " CHOICE

    case $CHOICE in
        1) prompt_log_file ;;
        2) [[ -z "$LOG_FILE" ]] && prompt_log_file; show_top_ips ;;
        3) [[ -z "$LOG_FILE" ]] && prompt_log_file; show_top_urls ;;
        4) [[ -z "$LOG_FILE" ]] && prompt_log_file; show_top_user_agents ;;
        5) [[ -z "$LOG_FILE" ]] && prompt_log_file; show_top_bots ;;
        6) show_server_load ;;
        7) show_server_stats ;;
        8) analyze_database ;;
        9) detect_server_load_source ;;
        10) echo "Выход."; exit 0 ;;
        *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
done
