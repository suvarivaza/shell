#!/bin/bash

# Путь до access.log
LOG_FILE=""

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'  # Reset to default color


prompt_log_file() {
    read -p "Введите путь до файла access.log: " LOG_FILE
    if [[ ! -f $LOG_FILE ]]; then
        echo "Файл $LOG_FILE не найден! Убедитесь, что путь указан правильно."
        exit 1
    fi
}


find_access_log(){
  sudo find / -type f -name "*access.log" 2>/dev/null
}

read_access_log() {
    tail -f $LOG_FILE
}

show_top_ips() {
    echo -e "${CYAN}==================== Топ IP адресов по нагрузке ====================${RESET}"
    awk '{print $1}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -n 10
}

show_top_urls() {
    echo -e "${CYAN}==================== Топ URL, к которым происходит обращение ====================${RESET}"
    awk '{print $7}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -n 10
}

show_top_user_agents() {
    echo -e "${CYAN}==================== Топ User-Agent ====================${RESET}"
    awk -F\" '{print $6}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -n 10
}

show_top_bots() {
    echo -e "${CYAN}==================== Топ ботов, сканирующих сайт ====================${RESET}"
    awk -F\" '{if ($6 ~ /bot|spider|crawler|crawl/i) print $6}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -n 10
}


function general_stats {
    echo -e "${CYAN}==================== General Stats ====================${RESET}"
    #Here we get OS version
    echo -e "${GREEN}OS Version: ${RESET}$(lsb_release -d | cut -f2-)"
    #Here we get system uptime
    echo -e "${GREEN}Uptime: ${RESET}$(uptime -p)"
    #Here we get load average (system load)
    echo -e "${GREEN}Load Average: ${RESET}$(cat /proc/loadavg | awk '{print $1, $2, $3}')"
    #Here we count logged in users
    logged_in_users=$(who | awk '{print $1}' | sort | uniq)
    echo -e "${GREEN}Logged in Users: ${RESET}$(who | wc -l)"
    echo -e "${GREEN}Usernames: ${RESET}${logged_in_users}"
    #Here we count failed login attempts
    echo -e "${GREEN}Failed Login Attempts: ${RESET}$(grep 'Failed password' /var/log/auth.log | wc -l)"
    echo
    cpu_usage
    echo
    memory_usage
    echo
    disk_usage
}


function cpu_usage {
    echo -e "${CYAN}==================== Total CPU Usage ====================${RESET}"

    #Here we read the first line of /proc/stat to get CPU usage
    read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat

    #Here we calculate total and used CPU time
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    used=$((user + nice + system + irq + softirq + steal))

    #Here we calculate CPU usage percentage
    cpu_usage_percentage=$((100 * used / total))

    echo -e "${GREEN}CPU Usage Percentage: ${RESET}${cpu_usage_percentage}%"
    echo

    echo -e "${CYAN}CPU load average:${RESET}"
    uptime

    echo
    top_cpu_processes
}


#Function to display top 5 processes by CPU usage
function top_cpu_processes {
    echo -e "${CYAN}==================== Top CPU processes ====================${RESET}"
    #Here we use ps to list processes sorted by CPU usage
    ps -eo pid,user,%cpu,%mem,command --sort=-%cpu | head -n 6
}


#Function to display total memory usage
function memory_usage {
    echo -e "${CYAN}==================== Total Memory Usage ====================${RESET}"
    #Here we use free to get memory usage and format the output
    free -h | awk 'NR==2{printf "Used: %s (%.2f%%)\nFree: %s\n", $3, $3*100/$2, $4}'
    echo
    echo -e "${CYAN}Memory Usage (free -h)${RESET}"
    free -h
    echo
    top_memory_processes
}


#Function to display top 5 processes by memory usage
function top_memory_processes {
    echo -e "${CYAN}==================== Top Memory processes ====================${RESET}"
    #Here we use ps to list processes sorted by memory usage
    ps -eo pid,user,%cpu,%mem,command --sort=-%mem | head -n 6
}

#Function to display total disk usage
function disk_usage {
    echo -e "${CYAN}==================== Total Disk Usage ====================${RESET}"
    #Here we use df to get disk usage and format the output for the root filesystem
    df -h | awk '$NF=="/"{printf "Used: %s (%.2f%%)\nFree: %s\n", $3, $3*100/$2, $4}'
    echo
    echo -e "${CYAN}Disk Usage (df -h)${RESET}"
    df -h
}


detect_server_load_source() {
    echo -e "${CYAN}==================== Определение источника нагрузки ====================${RESET}"
    CPU_LOAD=$(awk '{print $1}' /proc/loadavg)
    echo -e "${GREEN}Текущая загрузка CPU: ${RESET} ${CPU_LOAD}"
    WEB_LOAD=$(awk '{print $1}' "$LOG_FILE" | wc -l)
    DB_LOAD=$(mysql -e "SHOW PROCESSLIST;" 2>/dev/null | wc -l || echo "0")
    echo "Обращений к веб-серверу: $WEB_LOAD"
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

analyze_database() {
    echo -e "${CYAN}==================== Анализ работы базы данных ====================${RESET}"
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


# Меню
while true; do
    echo
    echo "Выберите действие:"
    echo "1. Общая статистика сервера"
    echo "2. Топ процессов нагружающих процессор"
    echo "3. Топ процессов занимающих память"

    echo "4. Найти все access.log"
    echo "5. Читать access.log"
    echo "6. Показать топ IP адресов по нагрузке (access.log)"
    echo "7. Показать топ URL, к которым происходит обращение (access.log)"
    echo "8. Показать топ User-Agent (access.log)"
    echo "9. Показать топ ботов, сканирующих сайт (access.log)"

    echo "10. Анализ базы данных (MySQL)"
    echo "11. Определить источник нагрузки"

    echo "0. Выход"
    echo
    read -p "Введите номер действия: " CHOICE

    case $CHOICE in
        1) general_stats ;;
        2) top_cpu_processes ;;
        3) top_memory_processes ;;
        4) find_access_log ;;
        5) [[ -z "$LOG_FILE" ]] && prompt_log_file; read_access_log ;;
        6) [[ -z "$LOG_FILE" ]] && prompt_log_file; show_top_ips ;;
        7) [[ -z "$LOG_FILE" ]] && prompt_log_file; show_top_urls ;;
        8) [[ -z "$LOG_FILE" ]] && prompt_log_file; show_top_user_agents ;;
        9) [[ -z "$LOG_FILE" ]] && prompt_log_file; show_top_bots ;;
        10) analyze_database ;;
        11) detect_server_load_source ;;
        0) echo "Выход."; exit 0 ;;
        *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
done
