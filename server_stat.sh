#!/bin/bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'  # Reset to default color

# Function to display total CPU usage
function cpu_usage {
    echo -e "${CYAN}==================== Total CPU Usage ====================${RESET}"
    read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    used=$((user + nice + system + irq + softirq + steal))
    cpu_usage_percentage=$((100 * used / total))
    echo "Cpu Usage Percentage: ${cpu_usage_percentage}%"
    echo "Load Average (1, 5, 15 minutes): $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
}

# Function to display total memory usage
function memory_usage {
    echo -e "${CYAN}==================== Total Memory Usage ====================${RESET}"
    free -h | awk 'NR==2{printf "Used: %s (%.2f%%)\nFree: %s\n", $3, $3*100/$2, $4}'
    echo "Swap Usage:"
    free -h | awk 'NR==4{printf "Used: %s\nFree: %s\n", $3, $4}'
}

# Function to display total disk usage
function disk_usage {
    echo -e "${CYAN}==================== Total Disk Usage ====================${RESET}"
    df -h | awk '$NF=="/"{printf "Used: %s (%.2f%%)\nFree: %s\n", $3, $3*100/$2, $4}'
    echo -e "\nTop directories consuming space in /:"
    du -ah / | sort -rh | head -n 10
}

# Function to display top 5 processes by CPU usage
function top_cpu_processes {
    echo -e "${CYAN}==================== Top 5 Processes by CPU Usage ====================${RESET}"
    ps -eo pid,comm,%cpu --sort=-%cpu | head -n 6
}

# Function to display top 5 processes by memory usage
function top_memory_processes {
    echo -e "${CYAN}==================== Top 5 Processes by Memory Usage ====================${RESET}"
    ps -eo pid,comm,%mem --sort=-%mem | head -n 6
}

# Function to display network activity
function network_activity {
    echo -e "${CYAN}==================== Network Activity ====================${RESET}"
    echo "Active Connections:"
    ss -tupn | awk 'NR > 1 {print $1, $5, $6}' | head -n 10
    echo
    echo "Total Incoming and Outgoing Packets:"
    ifconfig | awk '/RX packets|TX packets/ {print $1, $2, $3, $4}'
}

# Function to display server hardware info
function hardware_info {
    echo -e "${CYAN}==================== Hardware Information ====================${RESET}"
    echo "CPU Info:"
    lscpu | grep "Model name\|CPU(s):\|MHz"
    echo
    echo "Memory Info:"
    free -h | awk 'NR==1; NR==2'
    echo
    echo "Disk Info:"
    lsblk
}

# Function to display additional stats
function general_stats {
    echo -e "${CYAN}==================== General Stats ====================${RESET}"
    echo -e "${GREEN}OS Version: ${RESET}$(lsb_release -d | cut -f2-)"
    echo -e "${GREEN}Uptime: ${RESET}$(uptime -p)"
    echo -e "${GREEN}Logged in Users: ${RESET}$(who | wc -l)"
    cpu_usage
}

# Function to analyze server performance and provide recommendations
function performance_analysis {
    echo -e "${CYAN}==================== Performance Analysis ====================${RESET}"
    load_avg=$(cat /proc/loadavg | awk '{print $1}')
    cpu_cores=$(nproc)
    if (( $(echo "$load_avg > $cpu_cores" | bc -l) )); then
        echo -e "${RED}High system load detected!${RESET}"
        echo "Recommendations:"
        echo "- Check top processes consuming CPU using option 4."
        echo "- Optimize or restart services causing high load."
    else
        echo -e "${GREEN}System load is within normal range.${RESET}"
    fi
}

# Menu
while true; do
    echo
    echo -e "${YELLOW}==================== Server Monitoring Menu ====================${RESET}"
    echo "1. Использование CPU"
    echo "2. Использование памяти"
    echo "3. Использование диска"
    echo "4. Топ процессов по CPU"
    echo "5. Топ процессов по памяти"
    echo "6. Сетевая активность"
    echo "7. Информация о оборудовании"
    echo "8. Общая статистика сервера"
    echo "9. Анализ производительности"
    echo "0. Выход"
    echo
    read -p "Введите номер действия: " CHOICE

    case $CHOICE in
        1) cpu_usage ;;
        2) memory_usage ;;
        3) disk_usage ;;
        4) top_cpu_processes ;;
        5) top_memory_processes ;;
        6) network_activity ;;
        7) hardware_info ;;
        8) general_stats ;;
        9) performance_analysis ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный выбор. Пожалуйста, попробуйте снова.${RESET}" ;;
    esac
done