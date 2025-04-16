#!/bin/bash

# Загрузить переменные из файла .env
set -a
source .env
set +a

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'  # Reset to default color

function check_download_files_env_vars() {

  echo -e "${CYAN}==================== Проверяем переменные ====================${RESET}"

  if [[ -z "$LOCAL_PATH_SITE" ]]; then
      echo -e "${RED}Не задана переменная LOCAL_PATH_SITE!${RESET}"
      return 1
    else
      echo "LOCAL_PATH_SITE = $LOCAL_PATH_SITE"
  fi

  if [[ -z "$REMOTE_PATH_SITE" ]]; then
      echo -e "${RED}Не задана переменная REMOTE_PATH_SITE!${RESET}"
      return 1
    else
      echo "REMOTE_PATH_SITE = $REMOTE_PATH_SITE"
  fi


  if [[ -z "$SSH_USER" ]]; then
      echo -e "${RED}Не задана переменная SSH_USER!${RESET}"
      return 1
    else
      echo "SSH_USER = $SSH_USER"
  fi


  if [[ -z "$SSH_IP" ]]; then
      echo -e "${RED}Не задана переменная SSH_IP!${RESET}"
      return 1
    else
      echo "SSH_IP = $SSH_IP"
  fi


}

function check_local_dir() {

  echo -e "${CYAN}==================== Проверяем локальную дирректорию ====================${RESET}"

  if [ -d "$LOCAL_PATH_SITE" ] && [ "$(ls -A "$LOCAL_PATH_SITE")" ]; then
    echo -e "${RED}Директория: $LOCAL_PATH_SITE не пуста! Сначала очистите директорию! ${RESET}"
    return 1
  elif [ ! -d "$LOCAL_PATH_SITE" ]; then
    mkdir $LOCAL_PATH_SITE && echo "Создана директория $LOCAL_PATH_SITE" && return 0
  fi

  echo "OK"

}

function clear_local_dir() {

    echo -e "${CYAN}==================== Очищаем локальную директорию ====================${RESET}"

  if [[ -z "$LOCAL_PATH_SITE"  ]]; then
      echo -e "${RED}Не задана переменная LOCAL_PATH_SITE!${RESET}"
      return 1
  fi

  read -p "Вы уверены? Директория $LOCAL_PATH_SITE будет удалена! (Y/N) " ANSWER

  if [[ "$ANSWER" == "Y" ]]; then
    echo "OK"
    rm -r $LOCAL_PATH_SITE && mkdir $LOCAL_PATH_SITE && echo "Директория $LOCAL_PATH_SITE очищена!"
  fi
}

function download_files() {

  check_download_files_env_vars || return 1

  check_local_dir || return 1

  echo -e "${CYAN}==================== Проверяем команду ====================${RESET}"

  command="ssh -o ServerAliveInterval=30 $SSH_USER@$SSH_IP \"cd $REMOTE_PATH_SITE && tar $EXCLUDE_PATH -vczf - ./\" | tar xzf - -C $LOCAL_PATH_SITE"

  read -p "Команда верная? $command (Y/N) " ANSWER

  if [[ "$ANSWER" == "Y" ]]; then
    echo -e "${CYAN}==================== Начинаем скачивание ====================${RESET}"
    ssh -o ServerAliveInterval=30 $SSH_USER@$SSH_IP "cd $REMOTE_PATH_SITE && tar $EXCLUDE_PATH -vczf - ./" | tar xzf - -C $LOCAL_PATH_SITE
  fi

}

while true; do
  echo
  echo "Выберите действие:"
  echo "1. Скачать файлы сайта"
  echo "2. Очистить локаьлную директорию"
  echo "0. Выход"
  echo
  read -p "Введите номер действия: " CHOICE

  case $CHOICE in
  1) download_files ;;
  2) clear_local_dir ;;
  0) echo "Выход." && exit 0;;
  *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
  esac
done
