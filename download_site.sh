#!/bin/bash

# Загрузить переменные из файла .env
set -a
source .env
set +a

LOCAL_PATH_SITE="$LOCAL_PATH_SITE" # путь до локальной директории
SSH="$SSH_USER@$SSH_IP"
REMOTE_PATH_SITE="$REMOTE_PATH_SITE" # путь до директории на сервере
EXCLUDE_PATH="$EXCLUDE_PATH" # каки папки сайта не загружать " --exclude='works_files' --exclude='works_img' --exclude='app/logs' "

function request_LOCAL_PATH_SITE() {

  #  если не указан путь до локальной директории
  if [ -z "$LOCAL_PATH_SITE" ]; then

    read -p "Введите путь до локальной директории (в которую загружать файлы): " LOCAL_PATH_SITE

    if [[ -z "$LOCAL_PATH_SITE" ]]; then
      echo "Вы НЕ ввели LOCAL_PATH_SITE!!!"
      return 1
    else
      echo "LOCAL_PATH_SITE = $LOCAL_PATH_SITE"
    fi

  fi

  check_local_dir || return 1

}

function check_local_dir() {

  if [ -d "$LOCAL_PATH_SITE" ] && [ "$(ls -A "$LOCAL_PATH_SITE")" ]; then
    echo "Директория $LOCAL_PATH_SITE не пуста!" && clear_local_dir
  elif [ ! -d "$LOCAL_PATH_SITE" ]; then
    mkdir $LOCAL_PATH_SITE && echo "Создана директория $LOCAL_PATH_SITE" && return 0
  fi

}

function clear_local_dir() {

  if [[ -z "$LOCAL_PATH_SITE"  ]]; then
      echo "Не указана директория LOCAL_PATH_SITE!"
      return 1
  fi

  read -p "Вы уверены? Директория $LOCAL_PATH_SITE будет удалена! (Y/N) " ANSWER

  if [[ "$ANSWER" == "Y" ]]; then
      rm -r $LOCAL_PATH_SITE && mkdir $LOCAL_PATH_SITE && echo "Директория $LOCAL_PATH_SITE очищена!"
  fi
}

function request_ssh() {
  if [ -n "$SSH" ]; then
    return 0
  fi

  read -p "Введите SSH доступы к серверу в формате user@1.1.1.1: " SSH

  if [[ -z "$SSH" ]]; then
    echo "Вы не ввели SSH!"
    return 1
  else
    echo "SSH = $SSH"
  fi
}

function request_REMOTE_PATH_SITE() {

  if [ -n "$REMOTE_PATH_SITE" ]; then
    return 0
  fi

  read -p "Введите полный путь до директории на сервере с которой скачиваем файлы: " REMOTE_PATH_SITE

  if [[ -z "$REMOTE_PATH_SITE" ]]; then
    echo "Вы не ввели REMOTE_PATH_SITE!"
    return 1
  else
    echo "REMOTE_PATH_SITE = $REMOTE_PATH_SITE"
  fi

}

function request_exclude_path() {

    if [ -n "$EXCLUDE_PATH" ]; then
      return 0
    fi

  read -p "Нужно исключить какие либо директории? (Y/N) " ANSWER

    if [[ "$ANSWER" == "Y" ]]; then
          read -p "Введите директории которые нужно исключить в формате: --exclude='path1' --exclude='path2' ---exclude='path3': " EXCLUDE_PATH
    fi

}

function request_data_for_download_files() {
  request_LOCAL_PATH_SITE && request_ssh && request_REMOTE_PATH_SITE && request_exclude_path
}




function download_files() {

  if [[ -z "$LOCAL_PATH_SITE" || -z $SSH || -z $REMOTE_PATH_SITE ]]; then
    echo "Не хватает данных! Проверьте: LOCAL_PATH_SITE = $LOCAL_PATH_SITE SSH = $SSH REMOTE_PATH_SITE = $REMOTE_PATH_SITE"
    return 1
  fi

  DATA="ssh -o ServerAliveInterval=30 $SSH \"cd $REMOTE_PATH_SITE && tar $EXCLUDE_PATH -vczf - ./\" | tar xzf - -C $LOCAL_PATH_SITE"

  read -p "Команда верная? $DATA (Y/N) " ANSWER

  if [[ "$ANSWER" == "Y" ]]; then
    echo "Скачиваем файлы"
    ssh -o ServerAliveInterval=30 $SSH "cd $REMOTE_PATH_SITE && tar $EXCLUDE_PATH -vczf - ./" | tar xzf - -C $LOCAL_PATH_SITE
  fi

}

while true; do
  echo
  echo "Выберите действие:"
  echo "1. Скачать файлы сайта"
  echo "0. Выход"
  echo
  read -p "Введите номер действия: " CHOICE

  case $CHOICE in
  1) request_data_for_download_files && download_files ;;
  0) echo "Выход." && exit 0;;
  *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
  esac
done
