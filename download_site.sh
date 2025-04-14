#!/bin/bash

# Загрузить переменные из файла .env
set -a
source .env
set +a

LOCAL_FILES_PATH="$LOCAL_FILES_PATH" # путь до локальной директории
SSH="$SSH_USER@$SSH_IP"
REMOTE_FILES_PATH="$REMOTE_FILES_PATH" # путь до директории на сервере
EXCLUDE_PATH="$EXCLUDE_PATH" # каки папки сайта не загружать " --exclude='works_files' --exclude='works_img' --exclude='app/logs' "

function request_local_files_path() {

  #  если не указан путь до локальной директории
  if [ -z "$LOCAL_FILES_PATH" ]; then

    read -p "Введите путь до локальной директории (в которую загружать файлы): " LOCAL_FILES_PATH

    if [[ -z "$LOCAL_FILES_PATH" ]]; then
      echo "Вы НЕ ввели LOCAL_FILES_PATH!!!"
      return 1
    else
      echo "LOCAL_FILES_PATH = $LOCAL_FILES_PATH"
    fi

  fi

  check_local_dir && return 0 || return 1

}

function check_local_dir() {

  if [ -d "$LOCAL_FILES_PATH" ] && [ "$(ls -A "$LOCAL_FILES_PATH")" ]; then
    echo "Директория $LOCAL_FILES_PATH не пуста!" && clear_local_dir
  elif [ ! -d "$LOCAL_FILES_PATH" ]; then
    mkdir $LOCAL_FILES_PATH && echo "Создана директория $LOCAL_FILES_PATH" && return 0
  fi

}

function clear_local_dir() {

  if [[ -z "$LOCAL_FILES_PATH"  ]]; then
      echo "Не указана директория LOCAL_FILES_PATH!"
      return 1
  fi

  read -p "Вы уверены? Директория $LOCAL_FILES_PATH будет удалена! (Y/N) " ANSWER

  if [[ "$ANSWER" == "Y" ]]; then
      rm -r $LOCAL_FILES_PATH && mkdir $LOCAL_FILES_PATH && echo "Директория $LOCAL_FILES_PATH очищена!"
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

function request_remote_files_path() {

  if [ -n "$REMOTE_FILES_PATH" ]; then
    return 0
  fi

  read -p "Введите полный путь до директории на сервере с которой скачиваем файлы: " REMOTE_FILES_PATH

  if [[ -z "$REMOTE_FILES_PATH" ]]; then
    echo "Вы не ввели REMOTE_FILES_PATH!"
    return 1
  else
    echo "REMOTE_FILES_PATH = $REMOTE_FILES_PATH"
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
  request_local_files_path && request_ssh && request_remote_files_path && request_exclude_path
}




function download_files() {

  if [[ -z "$LOCAL_FILES_PATH" || -z $SSH || -z $REMOTE_FILES_PATH ]]; then
    echo "Не хватает данных! Проверьте: LOCAL_FILES_PATH = $LOCAL_FILES_PATH SSH = $SSH REMOTE_FILES_PATH = $REMOTE_FILES_PATH"
    return 1
  fi

  DATA="ssh -o ServerAliveInterval=30 $SSH \"cd $REMOTE_FILES_PATH && tar $EXCLUDE_PATH -vczf - ./\" | tar xzf - -C $LOCAL_FILES_PATH"

  read -p "Все верно? $DATA (Y/N) " ANSWER

  if [[ "$ANSWER" == "Y" ]]; then
    echo "Скачиваем файлы"
    ssh -o ServerAliveInterval=30 $SSH "cd $REMOTE_FILES_PATH && tar $EXCLUDE_PATH -vczf - ./" | tar xzf - -C $LOCAL_FILES_PATH
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
