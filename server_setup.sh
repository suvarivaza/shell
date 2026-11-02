#!/bin/bash

# Цвета вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

BACKUP_DIR="/root/server-setup-backups"

show_command() {
  local argument

  printf '  '
  for argument in "$@"; do
    printf '%q ' "$argument"
  done
  printf '\n'
}

show_append_line_command() {
  local value="$1"
  local target_file="$2"

  printf "  printf '%%s\\\\n' "
  printf '%q' "$value"
  printf ' | sudo tee -a %q >/dev/null\n' "$target_file"
}

show_save_command() {
  local source_command="$1"
  local target_file="$2"

  printf '  sudo %s | sudo tee %q >/dev/null\n' "$source_command" "$target_file"
}

show_command_plan_header() {
  echo -e "${CYAN}Будут выполнены следующие изменяющие команды:${RESET}"
}

run_command() {
  {
    echo -e "${CYAN}Выполняем команду:${RESET}"
    show_command "$@"
  } >&2
  "$@"
}

create_backup() {
  local source_file="$1"
  local timestamp
  local backup_file

  if ! sudo test -e "$source_file"; then
    return 0
  fi

  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_file="$BACKUP_DIR/$(basename "$source_file").$timestamp"
  run_command sudo mkdir -p "$BACKUP_DIR" || return 1
  run_command sudo cp -a "$source_file" "$backup_file" || return 1
  echo "$backup_file"
}

restore_backup() {
  local backup_file="$1"
  local target_file="$2"

  if [[ -n "$backup_file" ]] && sudo test -e "$backup_file"; then
    run_command sudo cp -a "$backup_file" "$target_file"
  else
    run_command sudo rm -f "$target_file"
  fi
}

systemd_unit_exists() {
  local unit_name="$1"

  if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit_name"; then
    return 0
  fi

  if [[ "$unit_name" != *.* ]] &&
     systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit_name.service"; then
    return 0
  fi

  return 1
}

get_ssh_service_name() {
  if systemd_unit_exists sshd.service && ! systemd_unit_exists ssh.service; then
    echo "sshd"
  else
    echo "ssh"
  fi
}

######### SSH ########


check_ssh_settings() {
  echo -e "${CYAN}==== Эффективные настройки SSH ====${RESET}"
  sudo sshd -T | grep -E '^(passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries|permitrootlogin) '
}

block_ssh_access_by_password() {
  local config_file="/etc/ssh/sshd_config.d/99-custom.conf"
  local backup_file=""
  local login_user="${SUDO_USER:-${USER:-root}}"
  local login_home
  local temp_file
  local confirmation
  local key_access_confirmation
  local ssh_service_name

  echo -e "${CYAN}==== Блокируем доступ к SSH по паролю ====${RESET}"

  login_home=$(getent passwd "$login_user" | cut -d: -f6)
  if [[ -z "$login_home" ]] ||
     { [[ ! -s "$login_home/.ssh/authorized_keys" ]] && sudo test ! -s /root/.ssh/authorized_keys; }; then
    echo -e "${RED}Не найден ни один непустой authorized_keys.${RESET}"
    echo "Сначала настройте и проверьте вход по SSH-ключу, затем повторите операцию."
    return 1
  fi

  echo -e "${YELLOW}Внимание: после отключения входа по паролю подключиться к серверу можно будет только по SSH-ключу.${RESET}"
  echo "Перед продолжением откройте второй терминал и убедитесь, что новое SSH-подключение по ключу работает."
  echo "Не закрывайте текущую SSH-сессию до завершения проверки."
  echo "Будет записан файл $config_file со значениями:"
  echo "  PubkeyAuthentication yes"
  echo "  PasswordAuthentication no"
  echo "  KbdInteractiveAuthentication no"
  echo "  ChallengeResponseAuthentication no"
  echo "  MaxAuthTries 5"
  ssh_service_name=$(get_ssh_service_name)
  show_command_plan_header
  show_command sudo sshd -t
  show_command sudo systemctl reload "$ssh_service_name"
  read -rp "Вы точно хотите отключить вход по SSH-паролю? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    echo "Операция отменена. Настройки SSH не изменены."
    return 0
  fi

  read -rp "Если вход по SSH-ключу уже проверен в отдельной сессии, введите ПРОВЕРЕН: " key_access_confirmation
  if [[ "$key_access_confirmation" != "ПРОВЕРЕН" ]]; then
    echo -e "${YELLOW}Подтверждение не получено. Настройки SSH не изменены.${RESET}"
    return 0
  fi

  backup_file=$(create_backup "$config_file") || return 1
  temp_file=$(mktemp) || return 1

  cat > "$temp_file" <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
MaxAuthTries 5
EOF

  run_command sudo mkdir -p /etc/ssh/sshd_config.d || return 1
  run_command sudo install -m 600 "$temp_file" "$config_file" || {
    rm -f "$temp_file"
    return 1
  }
  rm -f "$temp_file"

  if ! sudo sshd -t; then
    echo -e "${RED}Новая конфигурация SSH не прошла проверку. Возвращаем предыдущий файл.${RESET}"
    restore_backup "$backup_file" "$config_file"
    sudo sshd -t || echo -e "${RED}После отката конфигурация SSH всё ещё содержит ошибку.${RESET}"
    return 1
  fi

  reload_ssh || {
    echo -e "${RED}Не удалось перезагрузить SSH. Возвращаем предыдущую конфигурацию.${RESET}"
    restore_backup "$backup_file" "$config_file"
    sudo sshd -t && reload_ssh
    return 1
  }

  check_ssh_settings
  echo "Не закрывайте текущую сессию, пока не проверите вход по ключу во втором терминале."
}

check_ssh_connection_by_password() {
  echo -e "${CYAN}==== Проверка эффективной настройки входа по паролю ====${RESET}"

  if sudo sshd -T | grep -qx 'passwordauthentication no'; then
    echo -e "${GREEN}Вход по паролю отключён в эффективной конфигурации SSH.${RESET}"
  else
    echo -e "${RED}Вход по паролю не отключён в эффективной конфигурации SSH.${RESET}"
    return 1
  fi
}

reload_ssh() {
  local service_name

  service_name=$(get_ssh_service_name)

  run_command sudo systemctl reload "$service_name" || return 1
  sudo systemctl is-active --quiet "$service_name" || return 1
  echo -e "${GREEN}Служба $service_name перечитала конфигурацию и остаётся активной.${RESET}"
}

find_ssh_configs(){
  sudo grep -RnsE '^(Include|PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin|MaxAuthTries)' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null
}

has_sudo_admin_key() {
  local sudo_members
  local admin_user
  local admin_home
  local -a admin_users=()

  sudo_members=$(getent group sudo | cut -d: -f4)
  IFS=',' read -r -a admin_users <<< "$sudo_members"

  for admin_user in "${admin_users[@]}"; do
    [[ -n "$admin_user" ]] || continue
    admin_home=$(getent passwd "$admin_user" | cut -d: -f6)
    if [[ -n "$admin_home" ]] && sudo test -s "$admin_home/.ssh/authorized_keys"; then
      return 0
    fi
  done

  return 1
}

configure_root_ssh_access() {
  local config_file="/etc/ssh/sshd_config.d/98-root-access.conf"
  local backup_file=""
  local root_mode
  local confirmation
  local admin_access_confirmation
  local temp_file
  local ssh_service_name

  echo "1. Разрешить root только по SSH-ключу"
  echo "2. Полностью запретить вход root по SSH"
  echo "0. Отмена"
  read -rp "Выберите режим: " root_mode

  case "$root_mode" in
    1) root_mode="prohibit-password" ;;
    2) root_mode="no" ;;
    0) return 0 ;;
    *) echo -e "${RED}Неверный выбор.${RESET}"; return 1 ;;
  esac

  if [[ "$root_mode" == "no" ]]; then
    if ! has_sudo_admin_key; then
      echo -e "${RED}Не найден альтернативный администратор из группы sudo с установленным SSH-ключом.${RESET}"
      echo "Сначала создайте администратора, установите ключ и проверьте вход."
      return 1
    fi
    echo -e "${YELLOW}Вход root по SSH будет полностью запрещён.${RESET}"
    echo "Перед продолжением проверьте вход альтернативным администратором с sudo в отдельной SSH-сессии."
    read -rp "Если такой вход уже проверен, введите ПРОВЕРЕН: " admin_access_confirmation
    if [[ "$admin_access_confirmation" != "ПРОВЕРЕН" ]]; then
      echo -e "${YELLOW}Подтверждение не получено. Настройки SSH не изменены.${RESET}"
      return 0
    fi
  fi

  echo "Будет записан файл $config_file со значением: PermitRootLogin $root_mode"
  ssh_service_name=$(get_ssh_service_name)
  show_command_plan_header
  show_command sudo sshd -t
  show_command sudo systemctl reload "$ssh_service_name"
  read -rp "Применить PermitRootLogin $root_mode? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена."
    return 0
  fi

  backup_file=$(create_backup "$config_file") || return 1
  temp_file=$(mktemp) || return 1
  printf 'PermitRootLogin %s\n' "$root_mode" > "$temp_file"
  run_command sudo install -m 600 "$temp_file" "$config_file" || {
    rm -f "$temp_file"
    return 1
  }
  rm -f "$temp_file"

  if ! sudo sshd -t; then
    echo -e "${RED}Конфигурация SSH не прошла проверку. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$config_file"
    return 1
  fi

  reload_ssh || {
    restore_backup "$backup_file" "$config_file"
    sudo sshd -t && reload_ssh
    return 1
  }

  check_ssh_settings
  echo "Проверьте вход в новой сессии до закрытия текущего подключения."
}

######### Пользователи ########

create_new_user() {
  local username
  local confirmation

  echo "Создание нового пользователя..."
  read -rp "Введите имя пользователя: " username

  if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo -e "${RED}Недопустимое имя пользователя.${RESET}"
    return 1
  fi

  if getent passwd "$username" >/dev/null; then
    echo -e "${YELLOW}Пользователь $username уже существует.${RESET}"
    return 0
  fi

  show_command_plan_header
  show_command sudo adduser "$username"
  read -rp "Создать системного пользователя $username? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Пользователь не создан."
    return 0
  fi

  run_command sudo adduser "$username"
}

install_user_ssh_key() {
  local username
  local user_home
  local public_key
  local confirmation

  read -rp "Введите имя пользователя: " username
  if ! getent passwd "$username" >/dev/null; then
    echo -e "${RED}Пользователь $username не найден.${RESET}"
    return 1
  fi

  read -rp "Вставьте публичный SSH-ключ одной строкой: " public_key
  if [[ ! "$public_key" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
    echo -e "${RED}Строка не похожа на поддерживаемый публичный SSH-ключ.${RESET}"
    return 1
  fi

  user_home=$(getent passwd "$username" | cut -d: -f6)
  show_command_plan_header
  show_command sudo install -d -m 700 -o "$username" -g "$username" "$user_home/.ssh"
  show_append_line_command "$public_key" "$user_home/.ssh/authorized_keys"
  show_command sudo chown "$username:$username" "$user_home/.ssh/authorized_keys"
  show_command sudo chmod 600 "$user_home/.ssh/authorized_keys"
  read -rp "Добавить указанный SSH-ключ пользователю $username? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. SSH-ключ не изменён."
    return 0
  fi

  run_command sudo install -d -m 700 -o "$username" -g "$username" "$user_home/.ssh" || return 1
  if ! sudo grep -qxF "$public_key" "$user_home/.ssh/authorized_keys" 2>/dev/null; then
    echo -e "${CYAN}Выполняем команду:${RESET}"
    show_append_line_command "$public_key" "$user_home/.ssh/authorized_keys"
    printf '%s\n' "$public_key" | sudo tee -a "$user_home/.ssh/authorized_keys" >/dev/null || return 1
  fi
  run_command sudo chown "$username:$username" "$user_home/.ssh/authorized_keys" || return 1
  run_command sudo chmod 600 "$user_home/.ssh/authorized_keys" || return 1
  echo -e "${GREEN}Ключ установлен пользователю $username.${RESET}"
}

create_admin_user() {
  local username
  local confirmation

  read -rp "Введите имя нового администратора: " username
  if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo -e "${RED}Недопустимое имя пользователя.${RESET}"
    return 1
  fi

  if ! getent passwd "$username" >/dev/null; then
    show_command_plan_header
    show_command sudo adduser "$username"
    read -rp "Создать пользователя $username? [y/N]: " confirmation
    if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
      echo "Операция отменена. Пользователь не создан."
      return 0
    fi
    run_command sudo adduser "$username" || return 1
  fi

  show_command_plan_header
  show_command sudo usermod -aG sudo "$username"
  read -rp "Добавить пользователя $username в группу sudo? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Пользователь создан без административных прав."
    return 0
  fi

  run_command sudo usermod -aG sudo "$username" || return 1
  echo -e "${GREEN}Пользователь $username добавлен в группу sudo.${RESET}"
  echo "Теперь установите ему SSH-ключ и проверьте вход в отдельной сессии."
}

######### Fail2Ban ########

NGINX_ACCESS_LOG="/var/log/nginx/access.log"
EXIM_LOG="/var/log/exim4/mainlog"
FAIL2BAN_CONFIG="/etc/fail2ban/jail.d/99-server-setup.conf"
FAIL2BAN_ISPMANAGER_CONFIG="/etc/fail2ban/jail.local"

show_fail2ban_configs() {
  local config_file

  echo -e "${CYAN}=== Файлы конфигурации Fail2Ban ===${RESET}"
  for config_file in "$FAIL2BAN_ISPMANAGER_CONFIG" "$FAIL2BAN_CONFIG"; do
    echo
    echo "Файл: $config_file"
    if sudo test -f "$config_file"; then
      show_command sudo sed -n 1,240p "$config_file"
      sudo sed -n '1,240p' "$config_file"
    else
      echo "Файл отсутствует."
    fi
  done

  if command -v fail2ban-client >/dev/null 2>&1; then
    echo
    echo -e "${CYAN}=== Проверка конфигурации и активные jail ===${RESET}"
    show_command sudo fail2ban-client -t
    sudo fail2ban-client -t || true
    show_command sudo fail2ban-client status
    sudo fail2ban-client status || true
  fi
}

install_fail2ban() {
  local confirmation

  show_command_plan_header
  show_command sudo apt-get update
  show_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
  show_command sudo systemctl enable --now fail2ban
  read -rp "Установить Fail2Ban, включить его в автозагрузку и запустить? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Пакеты и службы не изменены."
    return 0
  fi

  echo "Устанавливаем Fail2Ban..."
  run_command sudo apt-get update || return 1
  run_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban || return 1
  run_command sudo systemctl enable --now fail2ban || return 1
  sudo systemctl is-active --quiet fail2ban || return 1
  echo -e "${GREEN}Fail2Ban установлен, включён в автозагрузку и запущен.${RESET}"
  show_fail2ban_configs
}

setup_fail2ban_base() {
  local backup_file=""
  local temp_file
  local confirmation

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    echo -e "${RED}Fail2Ban не установлен. Сначала выполните пункт установки.${RESET}"
    return 1
  fi

  echo "Будет создан или заменён управляемый файл $FAIL2BAN_CONFIG, затем Fail2Ban будет перезапущен."
  show_command_plan_header
  show_command sudo fail2ban-client -t
  show_command sudo systemctl restart fail2ban
  read -rp "Применить базовую конфигурацию Fail2Ban? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Конфигурация Fail2Ban не изменена."
    return 0
  fi

  echo "Настраиваем защиту SSH и доступные фильтры Nginx..."

  run_command sudo mkdir -p /etc/fail2ban/jail.d
  backup_file=$(create_backup "$FAIL2BAN_CONFIG") || return 1
  temp_file=$(mktemp) || return 1

  cat > "$temp_file" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
maxretry = 5
EOF

  if [[ -f /etc/fail2ban/filter.d/nginx-botsearch.conf && -f "$NGINX_ACCESS_LOG" ]]; then
    cat >> "$temp_file" <<EOF

[nginx-botsearch]
enabled = true
logpath = $NGINX_ACCESS_LOG
EOF
  fi

  if [[ -f /etc/fail2ban/filter.d/nginx-noscript.conf && -f "$NGINX_ACCESS_LOG" ]]; then
    cat >> "$temp_file" <<EOF

[nginx-noscript]
enabled = true
logpath = $NGINX_ACCESS_LOG
EOF
  fi

  if [[ -f /etc/fail2ban/filter.d/exim.conf && -f "$EXIM_LOG" ]]; then
    cat >> "$temp_file" <<EOF

[exim]
enabled = true
logpath = $EXIM_LOG
EOF
  fi

  run_command sudo install -m 640 "$temp_file" "$FAIL2BAN_CONFIG" || {
    rm -f "$temp_file"
    return 1
  }
  rm -f "$temp_file"

  if ! sudo fail2ban-client -t; then
    echo -e "${RED}Конфигурация Fail2Ban не прошла проверку. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$FAIL2BAN_CONFIG"
    sudo fail2ban-client -t || echo -e "${RED}После отката конфигурация Fail2Ban всё ещё содержит ошибку.${RESET}"
    return 1
  fi

  if ! run_command sudo systemctl restart fail2ban || ! sudo systemctl is-active --quiet fail2ban; then
    echo -e "${RED}Fail2Ban не запустился с новой конфигурацией. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$FAIL2BAN_CONFIG"
    sudo fail2ban-client -t && run_command sudo systemctl restart fail2ban
    return 1
  fi

  echo -e "${GREEN}Конфигурация Fail2Ban применена.${RESET}"
  show_fail2ban_configs
}

check_fail2ban() {
  echo "Общий статус Fail2Ban:"
  sudo systemctl status fail2ban --no-pager
  sudo fail2ban-client status
}

check_jail() {
  local jail

  echo "Доступные jail:"
  sudo fail2ban-client status
  echo ""
  read -rp "Введите имя jail (например, sshd): " jail
  if [[ ! "$jail" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}Недопустимое имя jail.${RESET}"
    return 1
  fi
  sudo fail2ban-client status "$jail"
}

fail2ban_log() {
  echo "Для выхода из просмотра нажмите Ctrl+C."
  sudo tail -f /var/log/fail2ban.log
}

######### Logwatch ########

LOGWATCH_CONFIG="/etc/logwatch/conf/logwatch.conf"
LOGWATCH_SERVICES_DIR="/usr/share/logwatch/scripts/services"

logwatch_status() {
  echo -e "${CYAN}=== Состояние Logwatch ===${RESET}"

  if command -v logwatch >/dev/null 2>&1; then
    show_command logwatch --version
    logwatch --version
  else
    echo "Logwatch не установлен."
  fi

  echo
  echo "Локальная конфигурация: $LOGWATCH_CONFIG"
  if sudo test -f "$LOGWATCH_CONFIG"; then
    show_command sudo sed -n 1,200p "$LOGWATCH_CONFIG"
    sudo sed -n '1,200p' "$LOGWATCH_CONFIG"
  else
    echo "Локальный файл конфигурации отсутствует."
  fi

  echo
  echo "Задания автоматического запуска:"
  sudo find /etc/cron.daily /etc/cron.d /etc/systemd/system /lib/systemd/system \
    -maxdepth 2 -iname '*logwatch*' -print 2>/dev/null || true
}

install_logwatch() {
  local confirmation

  if command -v logwatch >/dev/null 2>&1; then
    echo -e "${GREEN}Logwatch уже установлен.${RESET}"
    logwatch_status
    return 0
  fi

  show_command_plan_header
  show_command sudo apt-get update
  show_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y logwatch
  echo "Пакет может установить стандартное ежедневное cron-задание дистрибутива."
  echo "Почтовый адрес и состав отчёта настраиваются отдельным пунктом меню."
  read -rp "Установить Logwatch? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Пакеты не изменены."
    return 0
  fi

  run_command sudo apt-get update || return 1
  run_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y logwatch || return 1
  command -v logwatch >/dev/null 2>&1 || {
    echo -e "${RED}После установки команда logwatch не найдена.${RESET}"
    return 1
  }

  echo -e "${GREEN}Logwatch установлен.${RESET}"
  logwatch_status
}

list_logwatch_services() {
  if [[ ! -d "$LOGWATCH_SERVICES_DIR" ]]; then
    echo -e "${RED}Каталог анализаторов Logwatch не найден. Сначала установите Logwatch.${RESET}"
    return 1
  fi

  echo -e "${CYAN}=== Доступные анализаторы Logwatch ===${RESET}"
  show_command find "$LOGWATCH_SERVICES_DIR" -maxdepth 1 -type f -printf '%f\n'
  find "$LOGWATCH_SERVICES_DIR" -maxdepth 1 -type f -printf '%f\n' | sort
}

logwatch_yesterday_report() {
  if ! command -v logwatch >/dev/null 2>&1; then
    echo -e "${RED}Logwatch не установлен.${RESET}"
    return 1
  fi

  show_command sudo logwatch --output stdout --format text --range yesterday --detail Med --service All
  sudo logwatch --output stdout --format text --range yesterday --detail Med --service All
}

logwatch_selected_report() {
  local services_input
  local service_name
  local range
  local -a service_names=()
  local -a command=(sudo logwatch --output stdout --format text --detail High)

  if ! command -v logwatch >/dev/null 2>&1; then
    echo -e "${RED}Logwatch не установлен.${RESET}"
    return 1
  fi

  list_logwatch_services || return 1
  echo
  read -rp "Введите названия анализаторов через пробел: " services_input
  read -rp "Период [today/yesterday, по умолчанию today]: " range
  range="${range:-today}"

  if [[ "$range" != "today" && "$range" != "yesterday" ]]; then
    echo -e "${RED}Допустимы только значения today или yesterday.${RESET}"
    return 1
  fi

  read -r -a service_names <<< "$services_input"
  if ((${#service_names[@]} == 0)); then
    echo -e "${RED}Не указан ни один анализатор.${RESET}"
    return 1
  fi

  command+=(--range "$range")
  for service_name in "${service_names[@]}"; do
    if [[ ! "$service_name" =~ ^[a-zA-Z0-9_.+-]+$ ]] ||
       [[ ! -f "$LOGWATCH_SERVICES_DIR/$service_name" ]]; then
      echo -e "${RED}Анализатор не найден: $service_name${RESET}"
      return 1
    fi
    command+=(--service "$service_name")
  done

  show_command "${command[@]}"
  "${command[@]}"
}

configure_logwatch_email() {
  local mail_to
  local mail_from
  local hostname_value
  local backup_file=""
  local temp_file
  local confirmation

  if ! command -v logwatch >/dev/null 2>&1; then
    echo -e "${RED}Logwatch не установлен.${RESET}"
    return 1
  fi

  read -rp "Email получателя ежедневного отчёта: " mail_to
  if [[ ! "$mail_to" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo -e "${RED}Некорректный email получателя.${RESET}"
    return 1
  fi

  hostname_value=$(hostname -f 2>/dev/null || hostname)
  read -rp "Email отправителя [logwatch@$hostname_value]: " mail_from
  mail_from="${mail_from:-logwatch@$hostname_value}"
  if [[ ! "$mail_from" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo -e "${RED}Некорректный email отправителя.${RESET}"
    return 1
  fi

  echo "Будет настроен ежедневный отчёт по всем установленным анализаторам:"
  echo "  MailTo = $mail_to"
  echo "  MailFrom = $mail_from"
  echo "  Range = yesterday"
  echo "  Detail = Med"
  echo "  Service = All"
  echo "  Output = mail"
  echo "Файл: $LOGWATCH_CONFIG"
  show_command_plan_header
  echo "  Запись управляемого файла: $LOGWATCH_CONFIG"
  read -rp "Записать конфигурацию ежедневного почтового отчёта? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Конфигурация не изменена."
    return 0
  fi

  backup_file=$(create_backup "$LOGWATCH_CONFIG") || return 1
  temp_file=$(mktemp) || return 1
  cat > "$temp_file" <<EOF
# Управляемая конфигурация ежедневного отчёта Logwatch.
Output = mail
Format = text
MailTo = $mail_to
MailFrom = $mail_from
Range = yesterday
Detail = Med
Service = All
EOF

  run_command sudo mkdir -p /etc/logwatch/conf || {
    rm -f "$temp_file"
    return 1
  }
  run_command sudo install -m 644 "$temp_file" "$LOGWATCH_CONFIG" || {
    rm -f "$temp_file"
    restore_backup "$backup_file" "$LOGWATCH_CONFIG"
    return 1
  }
  rm -f "$temp_file"

  echo -e "${GREEN}Почтовый отчёт Logwatch настроен.${RESET}"
  echo "Перед ожиданием автоматического запуска проверьте доставку вручную:"
  show_command sudo logwatch --output mail --range today --detail Med --service All
  logwatch_status
}

logwatch_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Logwatch ===${RESET}"
    echo "1. Показать состояние и конфигурацию"
    echo "2. Установить Logwatch"
    echo "3. Отчёт по всем анализаторам за вчера"
    echo "4. Выборочный отчёт"
    echo "5. Показать доступные анализаторы"
    echo "6. Настроить ежедневный отчёт по email"
    echo "0. Назад в главное меню"
    echo
    read -rp "Выберите действие: " CHOICE

    case $CHOICE in
      1) logwatch_status ;;
      2) install_logwatch ;;
      3) logwatch_yesterday_report ;;
      4) logwatch_selected_report ;;
      5) list_logwatch_services ;;
      6) configure_logwatch_email ;;
      0) break ;;
      *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

######### GoAccess ########

goaccess_status() {
  echo -e "${CYAN}=== Состояние GoAccess ===${RESET}"

  if command -v goaccess >/dev/null 2>&1; then
    show_command goaccess --version
    goaccess --version
  else
    echo "GoAccess не установлен."
  fi

  echo
  echo "Найденные журналы доступа веб-серверов:"
  sudo find /var/log/nginx /var/log/apache2 /var/www/httpd-logs \
    -maxdepth 2 -type f \
    \( -name '*access*.log' -o -name '*access_log*' \) \
    -print 2>/dev/null | sort || true
}

install_goaccess() {
  local confirmation

  if command -v goaccess >/dev/null 2>&1; then
    echo -e "${GREEN}GoAccess уже установлен.${RESET}"
    goaccess_status
    return 0
  fi

  show_command_plan_header
  show_command sudo apt-get update
  show_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y goaccess
  read -rp "Установить GoAccess? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Пакеты не изменены."
    return 0
  fi

  run_command sudo apt-get update || return 1
  run_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y goaccess || return 1
  command -v goaccess >/dev/null 2>&1 || {
    echo -e "${RED}После установки команда goaccess не найдена.${RESET}"
    return 1
  }

  echo -e "${GREEN}GoAccess установлен.${RESET}"
  goaccess_status
}

run_goaccess() {
  local access_log_file

  if ! command -v goaccess >/dev/null 2>&1; then
    echo -e "${RED}GoAccess не установлен. Сначала выполните пункт установки.${RESET}"
    return 1
  fi

  goaccess_status
  echo
  read -er -p "Введите абсолютный путь к access.log: " access_log_file
  if [[ "$access_log_file" != /* ]]; then
    echo -e "${RED}Необходимо указать абсолютный путь к журналу.${RESET}"
    return 1
  fi
  if ! sudo test -f "$access_log_file"; then
    echo -e "${RED}Файл не найден: $access_log_file${RESET}"
    return 1
  fi
  if ! sudo test -r "$access_log_file"; then
    echo -e "${RED}Файл недоступен для чтения даже через sudo: $access_log_file${RESET}"
    return 1
  fi

  echo "GoAccess будет запущен в интерактивном режиме с форматом журнала COMBINED."
  echo "Для выхода из интерфейса GoAccess нажмите q."
  show_command sudo goaccess "$access_log_file" --log-format=COMBINED
  sudo goaccess "$access_log_file" --log-format=COMBINED
}

goaccess_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== GoAccess ===${RESET}"
    echo "1. Показать состояние и найденные access.log"
    echo "2. Установить GoAccess"
    echo "3. Проанализировать access.log интерактивно"
    echo "0. Назад в главное меню"
    echo
    read -rp "Выберите действие: " CHOICE

    case $CHOICE in
      1) goaccess_status ;;
      2) install_goaccess ;;
      3) run_goaccess ;;
      0) break ;;
      *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

######### Автоматические обновления безопасности ########

UNATTENDED_CONFIG="/etc/apt/apt.conf.d/20auto-upgrades"
UNATTENDED_ORIGINS_CONFIG="/etc/apt/apt.conf.d/52-server-setup-security-updates"

setup_security_updates() {
  local backup_file=""
  local origins_backup_file=""
  local temp_file
  local origins_temp_file
  local confirmation

  echo "Будет установлен unattended-upgrades, записаны настройки APT и включены системные таймеры обновлений."
  show_command_plan_header
  show_command sudo apt-get update
  show_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
  echo "  Запись управляемого файла: $UNATTENDED_CONFIG"
  echo "  Запись управляемого файла: $UNATTENDED_ORIGINS_CONFIG"
  show_command sudo unattended-upgrade --dry-run
  show_command sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
  read -rp "Включить автоматическую установку security-обновлений? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Настройки автоматических обновлений не изменены."
    return 0
  fi

  echo "Устанавливаем unattended-upgrades..."
  run_command sudo apt-get update || return 1
  run_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades || return 1

  backup_file=$(create_backup "$UNATTENDED_CONFIG") || return 1
  origins_backup_file=$(create_backup "$UNATTENDED_ORIGINS_CONFIG") || return 1
  temp_file=$(mktemp) || return 1
  origins_temp_file=$(mktemp) || {
    rm -f "$temp_file"
    return 1
  }
  cat > "$temp_file" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  run_command sudo install -m 644 "$temp_file" "$UNATTENDED_CONFIG" || {
    rm -f "$temp_file" "$origins_temp_file"
    return 1
  }
  rm -f "$temp_file"

  cat > "$origins_temp_file" <<'EOF'
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "codename=${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  run_command sudo install -m 644 "$origins_temp_file" "$UNATTENDED_ORIGINS_CONFIG" || {
    rm -f "$origins_temp_file"
    restore_backup "$backup_file" "$UNATTENDED_CONFIG"
    return 1
  }
  rm -f "$origins_temp_file"

  if ! sudo unattended-upgrade --dry-run; then
    echo -e "${RED}Проверочный запуск unattended-upgrades завершился с ошибкой. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$UNATTENDED_CONFIG"
    restore_backup "$origins_backup_file" "$UNATTENDED_ORIGINS_CONFIG"
    return 1
  fi

  if ! run_command sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer; then
    echo -e "${RED}Не удалось включить таймеры APT. Выполняем откат конфигурации.${RESET}"
    restore_backup "$backup_file" "$UNATTENDED_CONFIG"
    restore_backup "$origins_backup_file" "$UNATTENDED_ORIGINS_CONFIG"
    return 1
  fi
  echo -e "${GREEN}Автоматическая установка обновлений безопасности включена.${RESET}"
  echo "Автоматически устанавливаются только пакеты из репозитория с кодовым именем *-security."
}

check_security_updates() {
  echo -e "${CYAN}=== Автоматические обновления безопасности ===${RESET}"
  dpkg-query -W -f='${Status} ${Version}\n' unattended-upgrades 2>/dev/null || echo "Пакет не установлен."
  systemctl status apt-daily.timer apt-daily-upgrade.timer --no-pager || true
  systemctl list-timers 'apt-daily*' --all --no-pager || true
  echo
  echo "Эффективная конфигурация периодических обновлений:"
  apt-config dump | grep -E 'APT::Periodic|Unattended-Upgrade::(Allowed-Origins|Origins-Pattern)' || true
}

security_updates_log() {
  echo "Для выхода из просмотра нажмите Ctrl+C."
  sudo tail -n 100 -f /var/log/unattended-upgrades/unattended-upgrades.log
}



######### Система ########

system_info() {
  echo -e "${GREEN}Выполняю: cat /etc/os-release ${RESET}"
  cat /etc/os-release
  echo -e "${GREEN}Выполняю: hostnamectl ${RESET}"
  hostnamectl
}

all_services() {
  echo -e "${GREEN}Выполняю: systemctl list-units --type=service --no-pager ${RESET}"
  systemctl list-units --type=service --no-pager
}

system_log() {
  echo "Для выхода из просмотра нажмите Ctrl+C."
  echo -e "${GREEN}Выполняю: sudo tail -n 100 -f /var/log/syslog ${RESET}"
  sudo tail -n 100 -f /var/log/syslog
}

security_service_inventory() {
  local service_name
  local -a services=(
    ssh sshd nginx apache2 docker
    proftpd vsftpd pure-ftpd telnet telnet.socket
    mysql mariadb postgresql redis-server
    exim4 postfix dovecot
    fail2ban netfilter-persistent
  )

  echo -e "${CYAN}=== Инвентаризация потенциально значимых служб ===${RESET}"
  for service_name in "${services[@]}"; do
    if systemd_unit_exists "$service_name"; then
      printf '%-24s active=%-10s enabled=%s\n' \
        "$service_name" \
        "$(systemctl is-active "$service_name" 2>/dev/null || true)" \
        "$(systemctl is-enabled "$service_name" 2>/dev/null || true)"
    fi
  done

  echo
  echo "Слушающие процессы:"
  sudo ss -lntup
}

disable_unneeded_service() {
  local service_name
  local confirmation
  local candidate
  local -a allowed_services=(
    proftpd vsftpd pure-ftpd telnet telnet.socket
    mysql mariadb postgresql redis-server
    exim4 postfix dovecot
  )
  local allowed=0

  security_service_inventory
  echo
  read -rp "Введите точное имя службы, которую нужно остановить и отключить: " service_name

  for candidate in "${allowed_services[@]}"; do
    if [[ "$service_name" == "$candidate" ]]; then
      allowed=1
      break
    fi
  done

  if ((allowed == 0)); then
    echo -e "${RED}Эта служба не входит в ограниченный список отключаемых сервисов.${RESET}"
    echo "Для нестандартной службы сначала проверьте её назначение вручную."
    return 1
  fi

  if ! systemd_unit_exists "$service_name"; then
    echo "Служба $service_name не установлена."
    return 0
  fi

  echo -e "${YELLOW}Остановка базы данных или почтовой службы может нарушить работу сайтов и почты.${RESET}"
  show_command_plan_header
  show_command sudo systemctl disable --now "$service_name"
  read -rp "Введите точное имя '$service_name' ещё раз для подтверждения: " confirmation
  if [[ "$confirmation" != "$service_name" ]]; then
    echo "Операция отменена."
    return 0
  fi

  run_command sudo systemctl disable --now "$service_name" || return 1
  echo -e "${GREEN}Служба $service_name остановлена и отключена из автозагрузки.${RESET}"
  echo "Для возврата: sudo systemctl enable --now $service_name"
}

disable_proftpd() {
  local confirmation

  echo -e "${CYAN}=== Отключение FTP-сервера ProFTPD ===${RESET}"
  if ! systemd_unit_exists proftpd; then
    echo "Служба ProFTPD не установлена."
    echo "Проверяем, не слушает ли другой процесс стандартные FTP-порты 20 и 21:"
    sudo ss -lntup | awk '$5 ~ /:(20|21)$/ {print}'
    return 0
  fi

  echo "ProFTPD будет немедленно остановлен и исключён из автозагрузки."
  echo "Существующие FTP-подключения будут разорваны. SFTP через SSH это действие не отключает."
  show_command_plan_header
  show_command sudo systemctl disable --now proftpd
  read -rp "Для подтверждения отключения FTP введите proftpd: " confirmation
  if [[ "$confirmation" != "proftpd" ]]; then
    echo "Операция отменена. Служба не изменена."
    return 0
  fi

  run_command sudo systemctl disable --now proftpd || return 1

  echo
  echo "Состояние ProFTPD после отключения:"
  systemctl is-active proftpd 2>/dev/null || true
  systemctl is-enabled proftpd 2>/dev/null || true

  echo
  echo "Процессы, слушающие стандартные FTP-порты 20 и 21:"
  if ! sudo ss -lntup | awk '$5 ~ /:(20|21)$/ {found = 1; print} END {exit !found}'; then
    echo -e "${GREEN}Порты 20 и 21 не прослушиваются.${RESET}"
  else
    echo -e "${YELLOW}Порты 20 или 21 всё ещё прослушиваются другим процессом. Проверьте вывод выше.${RESET}"
  fi

  echo "Для возврата: sudo systemctl enable --now proftpd"
}

disable_mail_services() {
  local service_name
  local confirmation
  local -a mail_services=(
    exim4 postfix dovecot
    opendkim rspamd spamassassin spamd
    clamav-daemon clamav-freshclam
  )
  local -a installed_services=()

  echo -e "${CYAN}=== Отключение почтовых сервисов ===${RESET}"
  for service_name in "${mail_services[@]}"; do
    if systemd_unit_exists "$service_name"; then
      installed_services+=("$service_name")
    fi
  done

  if ((${#installed_services[@]} == 0)); then
    echo "Поддерживаемые почтовые службы не найдены."
    echo "Проверяем стандартные почтовые порты:"
    sudo ss -lntup | awk '$5 ~ /:(25|110|143|465|587|993|995)$/ {print}'
    return 0
  fi

  echo "Будут остановлены и отключены из автозагрузки найденные службы:"
  printf '  %s\n' "${installed_services[@]}"
  echo
  echo -e "${RED}После выполнения сервер перестанет обслуживать локальную почтовую систему.${RESET}"
  echo "Могут перестать работать:"
  echo "  - почтовые ящики и Roundcube в ISPmanager;"
  echo "  - отправка Joomla/PHP через mail() или локальный sendmail;"
  echo "  - системные, cron- и Logwatch-уведомления;"
  echo "  - получение почты по SMTP, IMAP и POP3."
  echo "Это действие допустимо, только если приложения используют внешний SMTP или вообще не отправляют почту."
  show_command_plan_header
  show_command sudo systemctl disable --now "${installed_services[@]}"
  read -rp "Для подтверждения введите ОТКЛЮЧИТЬ ПОЧТУ: " confirmation
  if [[ "$confirmation" != "ОТКЛЮЧИТЬ ПОЧТУ" ]]; then
    echo "Операция отменена. Почтовые службы не изменены."
    return 0
  fi

  run_command sudo systemctl disable --now "${installed_services[@]}" || return 1

  echo
  echo "Состояние почтовых служб после отключения:"
  for service_name in "${installed_services[@]}"; do
    printf '%-24s active=%-10s enabled=%s\n' \
      "$service_name" \
      "$(systemctl is-active "$service_name" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$service_name" 2>/dev/null || true)"
  done

  echo
  echo "Процессы, слушающие стандартные почтовые порты:"
  if ! sudo ss -lntup | awk '$5 ~ /:(25|110|143|465|587|993|995)$/ {found = 1; print} END {exit !found}'; then
    echo -e "${GREEN}Стандартные почтовые порты не прослушиваются.${RESET}"
  else
    echo -e "${YELLOW}Один или несколько почтовых портов всё ещё прослушиваются. Проверьте процесс в выводе выше.${RESET}"
  fi

  echo "Для возврата служб используйте:"
  show_command sudo systemctl enable --now "${installed_services[@]}"
}

######### nginx  ########

NGINX_BAD_ROBOT_CONFIG="/etc/nginx/vhosts-includes/bad_robot.conf"

nginx_status() {
  echo -e "${GREEN}Выполняю: sudo systemctl status nginx --no-pager ${RESET}"
  sudo systemctl status nginx --no-pager
}

nginx_reload() {
  local confirmation

  echo -e "${GREEN}Проверяем конфигурацию: sudo nginx -t ${RESET}"
  sudo nginx -t || {
    echo -e "${RED}Конфигурация Nginx содержит ошибку. Перезагрузка отменена.${RESET}"
    return 1
  }

  show_command_plan_header
  show_command sudo systemctl reload nginx
  read -rp "Конфигурация корректна. Перечитать конфигурацию Nginx? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Nginx не перечитывал конфигурацию."
    return 0
  fi

  run_command sudo systemctl reload nginx || return 1
  sudo systemctl is-active --quiet nginx || return 1
  echo -e "${GREEN}Nginx перечитал проверенную конфигурацию и остаётся активным.${RESET}"
}

show_bad_robot_config() {
  echo -e "${CYAN}=== Конфигурация блокировки ботов Nginx ===${RESET}"

  if sudo test -f "$NGINX_BAD_ROBOT_CONFIG"; then
    show_command sudo sed -n 1,200p "$NGINX_BAD_ROBOT_CONFIG"
    sudo sed -n '1,200p' "$NGINX_BAD_ROBOT_CONFIG"
  else
    echo "Файл $NGINX_BAD_ROBOT_CONFIG отсутствует."
  fi
}

install_bad_robot_config() {
  local backup_file=""
  local temp_file
  local confirmation

  temp_file=$(mktemp) || return 1
  cat > "$temp_file" <<'EOF'
# Блокировка нежелательных роботов по заголовку User-Agent.
# User-Agent легко подделать, поэтому правило является дополнительным фильтром,
# а не самостоятельной защитой от атак.
if ($http_user_agent ~* "(AhrefsBot|MJ12bot|masscan|WPScan|DotBot|Semrush|Screaming|Exabot|BLEXBot|MegaIndex|crawler4j|ZmEu|sqlmap|ltx71|nutch|python|pycurl|urllib|BlackWidow|HTTrack|Offline|ZyBorg)") {
    return 444;
}
EOF

  echo -e "${YELLOW}Шаблоны python, pycurl и urllib могут заблокировать легитимные API-клиенты, мониторинг или внутренние интеграции.${RESET}"
  echo "Будет записан файл $NGINX_BAD_ROBOT_CONFIG:"
  sed -n '1,200p' "$temp_file"
  show_command_plan_header
  show_command sudo mkdir -p "$(dirname "$NGINX_BAD_ROBOT_CONFIG")"
  show_command sudo install -m 644 "$temp_file" "$NGINX_BAD_ROBOT_CONFIG"
  show_command sudo nginx -t
  show_command sudo systemctl reload nginx
  read -rp "Установить или обновить блокировку ботов Nginx? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    rm -f "$temp_file"
    echo "Операция отменена. Конфигурация Nginx не изменена."
    return 0
  fi

  backup_file=$(create_backup "$NGINX_BAD_ROBOT_CONFIG") || {
    rm -f "$temp_file"
    return 1
  }
  run_command sudo mkdir -p "$(dirname "$NGINX_BAD_ROBOT_CONFIG")" || {
    rm -f "$temp_file"
    return 1
  }
  run_command sudo install -m 644 "$temp_file" "$NGINX_BAD_ROBOT_CONFIG" || {
    rm -f "$temp_file"
    return 1
  }
  rm -f "$temp_file"

  if ! sudo nginx -t; then
    echo -e "${RED}Конфигурация Nginx не прошла проверку. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$NGINX_BAD_ROBOT_CONFIG"
    sudo nginx -t || echo -e "${RED}После отката конфигурация Nginx всё ещё содержит ошибку.${RESET}"
    return 1
  fi

  if ! sudo nginx -T 2>&1 | grep -Fq "configuration file $NGINX_BAD_ROBOT_CONFIG:"; then
    echo -e "${RED}Nginx не подключил файл $NGINX_BAD_ROBOT_CONFIG. Выполняем откат.${RESET}"
    echo "На этом сервере каталог vhosts-includes не используется в активной конфигурации Nginx."
    restore_backup "$backup_file" "$NGINX_BAD_ROBOT_CONFIG"
    return 1
  fi

  if ! run_command sudo systemctl reload nginx || ! sudo systemctl is-active --quiet nginx; then
    echo -e "${RED}Nginx не перечитал новую конфигурацию. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$NGINX_BAD_ROBOT_CONFIG"
    sudo nginx -t && run_command sudo systemctl reload nginx
    return 1
  fi

  echo -e "${GREEN}Блокировка указанных User-Agent установлена.${RESET}"
}

remove_bad_robot_config() {
  local backup_file
  local confirmation

  if ! sudo test -f "$NGINX_BAD_ROBOT_CONFIG"; then
    echo "Файл $NGINX_BAD_ROBOT_CONFIG уже отсутствует."
    return 0
  fi

  show_bad_robot_config
  show_command_plan_header
  show_command sudo rm -f "$NGINX_BAD_ROBOT_CONFIG"
  show_command sudo nginx -t
  show_command sudo systemctl reload nginx
  read -rp "Удалить блокировку ботов Nginx? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Конфигурация Nginx не изменена."
    return 0
  fi

  backup_file=$(create_backup "$NGINX_BAD_ROBOT_CONFIG") || return 1
  run_command sudo rm -f "$NGINX_BAD_ROBOT_CONFIG" || return 1

  if ! sudo nginx -t; then
    echo -e "${RED}Конфигурация Nginx не прошла проверку после удаления. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$NGINX_BAD_ROBOT_CONFIG"
    return 1
  fi

  if ! run_command sudo systemctl reload nginx || ! sudo systemctl is-active --quiet nginx; then
    echo -e "${RED}Nginx не перечитал конфигурацию. Выполняем откат.${RESET}"
    restore_backup "$backup_file" "$NGINX_BAD_ROBOT_CONFIG"
    sudo nginx -t && run_command sudo systemctl reload nginx
    return 1
  fi

  echo -e "${GREEN}Блокировка ботов Nginx удалена.${RESET}"
}

######### Сеть ########

open_ports() {
  echo -e "${GREEN}Выполняю: sudo ss -lntup ${RESET}"
  sudo ss -lntup
}

potentially_public_ports() {
  echo -e "${CYAN}=== Сокеты, слушающие не только локальный интерфейс ===${RESET}"
  echo "Показываются TCP- и UDP-сокеты, которые не привязаны к 127.0.0.1 или ::1."
  echo -e "${YELLOW}Это потенциально публичные порты, а не доказательство доступности из интернета.${RESET}"
  echo "Фактический доступ также зависит от iptables, внешнего фаервола, NAT и маршрутизации."
  echo -e "${GREEN}Выполняю: sudo ss -H -lntup | awk '<исключение loopback-адресов>' ${RESET}"

  sudo ss -H -lntup | awk '
    {
      local_address = $5
      if (local_address !~ /^127\./ &&
          local_address !~ /^\[?::1\]?:/) {
        print
      }
    }
  '

  echo
  echo "Для точной проверки запустите с другого сервера:"
  echo "  nmap -Pn -sS -sV <публичный-IP>"
  echo "UDP проверяется отдельно и значительно медленнее:"
  echo "  sudo nmap -Pn -sU --top-ports 100 <публичный-IP>"
}

filesystem_security_audit() {
  local web_root="/var/www"

  echo -e "${CYAN}=== Проверка безопасности файловой системы ===${RESET}"

  if [[ ! -d "$web_root" ]]; then
    echo "Каталог $web_root отсутствует."
    return 0
  fi

  echo
  echo -e "${BLUE}Файлы и каталоги с правами записи для всех в $web_root:${RESET}"
  sudo find "$web_root" -xdev -perm -0002 -printf '%m %u:%g %p\n' 2>/dev/null || true

  echo
  echo -e "${BLUE}Потенциально чувствительные конфигурационные файлы:${RESET}"
  sudo find "$web_root" -xdev -type f \
    \( -name '.env' -o -name 'configuration.php' -o -name 'wp-config.php' -o -name '*.key' -o -name '*.pem' \) \
    -printf '%m %u:%g %p\n' 2>/dev/null || true

  echo
  echo -e "${BLUE}Чувствительные конфигурационные файлы, доступные для чтения всем:${RESET}"
  sudo find "$web_root" -xdev -type f -perm -0004 \
    \( -name '.env' -o -name 'configuration.php' -o -name 'wp-config.php' -o -name '*.key' -o -name '*.pem' \) \
    -printf '%m %u:%g %p\n' 2>/dev/null || true

  echo
  echo -e "${BLUE}Приватные SSH-файлы с доступом для группы или остальных:${RESET}"
  sudo find /root /home -xdev -type f -path '*/.ssh/*' ! -name '*.pub' \
    -perm /077 -printf '%m %u:%g %p\n' 2>/dev/null || true

  echo
  echo -e "${BLUE}Каталоги веб-сайтов, принадлежащие www-data и доступные ему для записи:${RESET}"
  sudo find "$web_root" -xdev -type d -user www-data -perm -u+w \
    -printf '%m %u:%g %p\n' 2>/dev/null || true

  echo
  echo "Пустой раздел означает, что соответствующие проблемы не найдены."
  echo "Найденные writable-каталоги нужно оценивать вручную: cache, logs и uploads могут быть легитимными."
}

collect_security_report() {
  local service_name

  echo -e "${CYAN}=== Аудит безопасности без изменения системы ===${RESET}"
  echo
  echo -e "${BLUE}Система:${RESET}"
  grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
  uname -r

  echo
  echo -e "${BLUE}Эффективные настройки SSH:${RESET}"
  sudo sshd -T 2>/dev/null |
    grep -E '^(passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries|permitrootlogin) ' || true

  echo
  echo -e "${BLUE}Службы безопасности и сетевые службы:${RESET}"
  for service_name in ssh sshd nginx docker fail2ban netfilter-persistent proftpd; do
    if systemd_unit_exists "$service_name"; then
      printf '%-24s active=%-10s enabled=%s\n' \
        "$service_name" \
        "$(systemctl is-active "$service_name" 2>/dev/null || true)" \
        "$(systemctl is-enabled "$service_name" 2>/dev/null || true)"
    fi
  done

  echo
  echo -e "${BLUE}Все активные службы:${RESET}"
  systemctl list-units --type=service --state=running --no-pager

  echo
  echo -e "${BLUE}Открытые TCP/UDP-порты:${RESET}"
  sudo ss -lntup

  echo
  echo -e "${BLUE}Потенциально публичные TCP/UDP-порты:${RESET}"
  sudo ss -H -lntup | awk '
    {
      local_address = $5
      if (local_address !~ /^127\./ &&
          local_address !~ /^\[?::1\]?:/) {
        print
      }
    }
  '
  echo "Фактическая доступность должна проверяться с внешнего хоста."

  echo
  echo -e "${BLUE}Пользователи с UID 0:${RESET}"
  awk -F: '$3 == 0 {print $1 " (" $7 ")"}' /etc/passwd

  echo
  echo -e "${BLUE}Пользователи с интерактивной оболочкой:${RESET}"
  awk -F: '$7 !~ /(nologin|false)$/ {print $1 " uid=" $3 " shell=" $7}' /etc/passwd

  echo
  echo -e "${BLUE}Группа sudo:${RESET}"
  getent group sudo || true

  echo
  echo -e "${BLUE}Установленные SSH-ключи пользователей:${RESET}"
  while IFS= read -r authorized_keys_file; do
    echo "$authorized_keys_file"
    sudo ssh-keygen -lf "$authorized_keys_file" 2>/dev/null || echo "  Не удалось прочитать ключи."
  done < <(sudo find /root /home -xdev -type f -path '*/.ssh/authorized_keys' 2>/dev/null)

  echo
  echo -e "${BLUE}Fail2Ban:${RESET}"
  if command -v fail2ban-client >/dev/null 2>&1; then
    sudo fail2ban-client status || true
  else
    echo "Fail2Ban не установлен."
  fi

  echo
  echo -e "${BLUE}Фаервол INPUT:${RESET}"
  sudo iptables -w 5 -L INPUT -n -v --line-numbers
  sudo ip6tables -w 5 -L INPUT -n -v --line-numbers

  echo
  echo -e "${BLUE}Сохранение правил фаервола:${RESET}"
  systemctl is-enabled netfilter-persistent 2>/dev/null || true
  systemctl is-active netfilter-persistent 2>/dev/null || true

  echo
  echo -e "${BLUE}Автоматические обновления:${RESET}"
  systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true
  systemctl is-active apt-daily-upgrade.timer 2>/dev/null || true
  apt-config dump | grep -E 'APT::Periodic|Unattended-Upgrade::(Allowed-Origins|Origins-Pattern)' || true

  echo
  echo -e "${BLUE}Доступные обновления пакетов:${RESET}"
  apt list --upgradable 2>/dev/null || true

  echo
  echo -e "${GREEN}Аудит завершён. Скрипт ничего не изменял.${RESET}"
}

security_audit() {
  collect_security_report
}

save_security_report() {
  local report_file

  report_file="${PWD}/server-security-report-$(date +%Y%m%d-%H%M%S).txt"
  {
    collect_security_report
    echo
    filesystem_security_audit
  } 2>&1 | tee "$report_file"
  echo
  echo -e "${GREEN}Отчёт сохранён: $report_file${RESET}"
}

# Подменю nginx
nginx_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Nginx ===${RESET}"
    echo "1. Показать статус Nginx"
    echo "2. Проверить конфигурацию и перечитать её"
    echo "3. Показать конфигурацию блокировки ботов"
    echo "4. Установить или обновить блокировку ботов"
    echo "5. Удалить блокировку ботов"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) nginx_status ;;
    2) nginx_reload ;;
    3) show_bad_robot_config ;;
    4) install_bad_robot_config ;;
    5) remove_bad_robot_config ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю system
system_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Система ===${RESET}"
    echo "1. Информация о системе"
    echo "2. Все сервисы"
    echo "3. Системные логи"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) system_info ;;
    2) all_services ;;
    3) system_log ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю пользователей
user_settings_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Пользователи ===${RESET}"
    echo "1. Создать нового пользователя"
    echo "2. Создать администратора с правами sudo"
    echo "3. Установить публичный SSH-ключ пользователю"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) create_new_user ;;
    2) create_admin_user ;;
    3) install_user_ssh_key ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю сети
network_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Сеть ===${RESET}"
    echo "1. Все слушающие порты"
    echo "2. Потенциально открытые наружу порты"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) open_ports ;;
    2) potentially_public_ports ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю Fail2ban
fail2ban_settings_menu() {
  while true; do
    echo ""
    echo "=== Fail2Ban ==="
    echo "1. Установить Fail2Ban"
    echo "2. Показать общий статус"
    echo "3. Показать статус определённого jail"
    echo "4. Настроить защиту SSH и доступные фильтры Nginx"
    echo "5. Смотреть журнал"
    echo "6. Показать файлы конфигурации и активные jail"
    echo "0. Назад"

    read -rp "Выберите действие [0-6]: " CHOICE

    case $CHOICE in
      1) install_fail2ban ;;
      2) check_fail2ban ;;
      3) check_jail ;;
      4) setup_fail2ban_base ;;
      5) fail2ban_log ;;
      6) show_fail2ban_configs ;;
      0) break ;;
      *) echo "Неверный выбор." ;;
    esac
  done
}

# Подменю SSH
ssh_settings_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== SSH ===${RESET}"
    echo "1. Проверить SSH настройки"
    echo "2. Заблокировать доступ к SSH по паролю"
    echo "3. Проверить, отключён ли пароль в эффективной конфигурации"
    echo "4. Найти настройки во всех SSH-конфигах"
    echo "5. Настроить доступ root по SSH"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) check_ssh_settings ;;
    2) block_ssh_access_by_password ;;
    3) check_ssh_connection_by_password ;;
    4) find_ssh_configs ;;
    5) configure_root_ssh_access ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

security_updates_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Автоматические обновления безопасности ===${RESET}"
    echo "1. Установить и включить security-обновления"
    echo "2. Проверить состояние и таймеры"
    echo "3. Смотреть журнал unattended-upgrades"
    echo "0. Назад в главное меню"
    read -rp "Выберите действие: " CHOICE

    case $CHOICE in
      1) setup_security_updates ;;
      2) check_security_updates ;;
      3) security_updates_log ;;
      0) break ;;
      *) echo "Неверный выбор." ;;
    esac
  done
}

services_security_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Инвентаризация служб ===${RESET}"
    echo "1. Показать значимые службы и открытые порты"
    echo "2. Остановить и отключить выбранную ненужную службу"
    echo "3. Отключить FTP-сервер ProFTPD"
    echo "4. Отключить почтовые сервисы"
    echo "0. Назад в главное меню"
    read -rp "Выберите действие: " CHOICE

    case $CHOICE in
      1) security_service_inventory ;;
      2) disable_unneeded_service ;;
      3) disable_proftpd ;;
      4) disable_mail_services ;;
      0) break ;;
      *) echo "Неверный выбор." ;;
    esac
  done
}

rules_iptables() {
  echo -e "${GREEN}Выполняю: sudo iptables -L -n --line-numbers ${RESET}"
  sudo iptables -w 5 -L -n --line-numbers
}

backup_firewall_rules() {
  local timestamp
  local backup_path

  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_path="$BACKUP_DIR/firewall-$timestamp"
  run_command sudo mkdir -p "$backup_path" || return 1
  {
    echo -e "${CYAN}Выполняем команду:${RESET}"
    show_save_command iptables-save "$backup_path/rules.v4"
  } >&2
  sudo iptables-save | sudo tee "$backup_path/rules.v4" >/dev/null || return 1
  {
    echo -e "${CYAN}Выполняем команду:${RESET}"
    show_save_command ip6tables-save "$backup_path/rules.v6"
  } >&2
  sudo ip6tables-save | sudo tee "$backup_path/rules.v6" >/dev/null || return 1

  if command -v ipset >/dev/null 2>&1; then
    {
      echo -e "${CYAN}Выполняем команду:${RESET}"
      show_save_command "ipset save" "$backup_path/ipsets"
    } >&2
    sudo ipset save | sudo tee "$backup_path/ipsets" >/dev/null || return 1
  fi

  echo "$backup_path"
}

restore_firewall_rules() {
  local backup_path="$1"

  if [[ -z "$backup_path" ]] || ! sudo test -d "$backup_path"; then
    echo -e "${RED}Каталог резервной копии фаервола не найден.${RESET}"
    return 1
  fi

  if sudo test -s "$backup_path/ipsets" && command -v ipset >/dev/null 2>&1; then
    run_command sudo ipset restore -exist -file "$backup_path/ipsets" || return 1
  fi
  run_command sudo iptables-restore "$backup_path/rules.v4" || return 1
  run_command sudo ip6tables-restore "$backup_path/rules.v6" || return 1
  echo -e "${GREEN}Активные правила восстановлены из $backup_path.${RESET}"
}

setup_iptables_persistence() {
  local -a required_packages=("iptables-persistent")
  local -a missing_packages=()
  local package_name

  # Правила ISPmanager могут ссылаться на динамические наборы ipset. В таком
  # случае наборы необходимо восстанавливать раньше правил IPv4 и IPv6.
  if sudo iptables-save | grep -q -- '--match-set' ||
     sudo ip6tables-save | grep -q -- '--match-set'; then
    required_packages+=("ipset-persistent")
  fi

  for package_name in "${required_packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null |
         grep -q '^install ok installed$'; then
      missing_packages+=("$package_name")
    fi
  done

  if ((${#missing_packages[@]} > 0)); then
    echo "Устанавливаем пакеты для автоматического восстановления фаервола: ${missing_packages[*]}"
    run_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}" || return 1
  fi

  run_command sudo systemctl enable netfilter-persistent || return 1
  run_command sudo netfilter-persistent save || return 1

  if [[ -f /etc/iptables/ipsets ]] && command -v ipset >/dev/null 2>&1; then
    run_command sudo ipset restore -exist -file /etc/iptables/ipsets || return 1
  fi

  sudo iptables-restore --test /etc/iptables/rules.v4 || return 1
  sudo ip6tables-restore --test /etc/iptables/rules.v6 || return 1

  echo -e "${GREEN}Правила сохранены через netfilter-persistent.${RESET}"
  echo "IPv4: /etc/iptables/rules.v4"
  echo "IPv6: /etc/iptables/rules.v6"

  if [[ -f /etc/iptables/ipsets ]]; then
    echo "IP-наборы: /etc/iptables/ipsets"
  fi

  echo "Служба включена в автозагрузку:"
  sudo systemctl is-enabled netfilter-persistent
}

check_iptables_persistence() {
  echo -e "${CYAN}=== Состояние сохранения правил фаервола ===${RESET}"
  sudo systemctl is-enabled netfilter-persistent || true
  sudo systemctl is-active netfilter-persistent || true

  for rules_file in /etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/iptables/ipsets; do
    if sudo test -f "$rules_file"; then
      sudo ls -lh "$rules_file"
    else
      echo "Файл отсутствует: $rules_file"
    fi
  done

  if sudo test -f /etc/iptables/rules.v4; then
    sudo iptables-restore --test /etc/iptables/rules.v4
  fi
  if sudo test -f /etc/iptables/rules.v6; then
    sudo ip6tables-restore --test /etc/iptables/rules.v6
  fi
}

is_valid_ipv4() {
  local ip="$1"
  local octet
  local -a octets=()

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

restrict_ispmanager_access() {
  local chain_name="ISPMGR_ACCESS"
  local chain6_name="ISPMGR6_ACCESS"
  local detected_ip=""
  local allowed_ip_input
  local allowed_ip
  local confirmation
  local firewall_backup
  local -a allowed_ips=()

  echo -e "${CYAN}=== Ограничение доступа к ISPmanager ===${RESET}"
  echo "Будет разрешён доступ к TCP-порту 1500 только с указанных IPv4-адресов."

  if [[ -n "${SSH_CLIENT:-}" ]]; then
    detected_ip="${SSH_CLIENT%% *}"
    echo "IP текущего SSH-подключения: $detected_ip"
  fi

  read -rp "Введите разрешённые IPv4-адреса через пробел${detected_ip:+ [по умолчанию: $detected_ip]}: " allowed_ip_input

  if [[ -z "$allowed_ip_input" && -n "$detected_ip" ]]; then
    allowed_ip_input="$detected_ip"
  fi

  # Разрешаем вводить адреса как через пробел, так и через запятую.
  allowed_ip_input="${allowed_ip_input//,/ }"

  for allowed_ip in $allowed_ip_input; do
    if ! is_valid_ipv4 "$allowed_ip"; then
      echo -e "${RED}Некорректный IPv4-адрес: $allowed_ip. Правила не изменены.${RESET}"
      return 1
    fi
    allowed_ips+=("$allowed_ip")
  done

  if ((${#allowed_ips[@]} == 0)); then
    echo -e "${RED}Не указан ни один разрешённый IPv4-адрес. Правила не изменены.${RESET}"
    return 1
  fi

  echo "Будут разрешены адреса: ${allowed_ips[*]}"
  show_command_plan_header
  if ! sudo iptables -w 5 -nL "$chain_name" >/dev/null 2>&1; then
    show_command sudo iptables -w 5 -N "$chain_name"
  fi
  show_command sudo iptables -w 5 -F "$chain_name"
  show_command sudo iptables -w 5 -A "$chain_name" -j DROP
  for allowed_ip in "${allowed_ips[@]}"; do
    show_command sudo iptables -w 5 -I "$chain_name" 1 -s "$allowed_ip/32" -j ACCEPT
  done
  if sudo iptables -w 5 -C INPUT -p tcp --dport 1500 -j "$chain_name" >/dev/null 2>&1; then
    show_command sudo iptables -w 5 -D INPUT -p tcp --dport 1500 -j "$chain_name"
  fi
  show_command sudo iptables -w 5 -I INPUT 1 -p tcp --dport 1500 -j "$chain_name"
  if ! sudo ip6tables -w 5 -nL "$chain6_name" >/dev/null 2>&1; then
    show_command sudo ip6tables -w 5 -N "$chain6_name"
  fi
  show_command sudo ip6tables -w 5 -F "$chain6_name"
  show_command sudo ip6tables -w 5 -A "$chain6_name" -j DROP
  if sudo ip6tables -w 5 -C INPUT -p tcp --dport 1500 -j "$chain6_name" >/dev/null 2>&1; then
    show_command sudo ip6tables -w 5 -D INPUT -p tcp --dport 1500 -j "$chain6_name"
  fi
  show_command sudo ip6tables -w 5 -I INPUT 1 -p tcp --dport 1500 -j "$chain6_name"
  show_command sudo netfilter-persistent save
  read -rp "Применить ограничение доступа к ISPmanager? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена."
    return 0
  fi

  firewall_backup=$(backup_firewall_rules) || {
    echo -e "${RED}Не удалось создать резервную копию правил. Изменения отменены.${RESET}"
    return 1
  }
  echo "Резервная копия фаервола: $firewall_backup"

  # Используем отдельную цепочку, чтобы повторный запуск заменял только правила,
  # созданные этим скриптом, и не затрагивал остальную конфигурацию INPUT.
  if ! sudo iptables -w 5 -nL "$chain_name" >/dev/null 2>&1; then
    run_command sudo iptables -w 5 -N "$chain_name" || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  fi

  run_command sudo iptables -w 5 -F "$chain_name" || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }

  # Сначала устанавливаем запрет по умолчанию. Это не оставляет порт открытым,
  # даже если добавление одного из разрешающих правил завершится ошибкой.
  run_command sudo iptables -w 5 -A "$chain_name" -j DROP || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }

  for allowed_ip in "${allowed_ips[@]}"; do
    run_command sudo iptables -w 5 -I "$chain_name" 1 -s "$allowed_ip/32" -j ACCEPT || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  done

  # Удаляем прежние переходы в управляемую цепочку, чтобы не создавать дубликаты.
  while sudo iptables -w 5 -C INPUT -p tcp --dport 1500 -j "$chain_name" >/dev/null 2>&1; do
    run_command sudo iptables -w 5 -D INPUT -p tcp --dport 1500 -j "$chain_name" || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  done

  run_command sudo iptables -w 5 -I INPUT 1 -p tcp --dport 1500 -j "$chain_name" || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }

  # Разрешённые адреса вводятся в формате IPv4. Чтобы порт не оставался
  # доступным в обход allowlist, полностью закрываем его по IPv6.
  if ! sudo ip6tables -w 5 -nL "$chain6_name" >/dev/null 2>&1; then
    run_command sudo ip6tables -w 5 -N "$chain6_name" || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  fi
  run_command sudo ip6tables -w 5 -F "$chain6_name" || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }
  run_command sudo ip6tables -w 5 -A "$chain6_name" -j DROP || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }
  while sudo ip6tables -w 5 -C INPUT -p tcp --dport 1500 -j "$chain6_name" >/dev/null 2>&1; do
    run_command sudo ip6tables -w 5 -D INPUT -p tcp --dport 1500 -j "$chain6_name" || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  done
  run_command sudo ip6tables -w 5 -I INPUT 1 -p tcp --dport 1500 -j "$chain6_name" || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }

  # Сохраняем правила и включаем их автоматическое восстановление после загрузки.
  # Службу здесь не перезапускаем, чтобы не рисковать текущим SSH-подключением.
  if ! setup_iptables_persistence; then
    echo -e "${RED}Не удалось сохранить правила. Выполняем откат активного фаервола.${RESET}"
    restore_firewall_rules "$firewall_backup"
    return 1
  fi

  echo -e "${GREEN}Доступ к ISPmanager ограничен.${RESET}"
  sudo iptables -w 5 -L INPUT -n -v --line-numbers | grep -E "Chain|1500|$chain_name" || true
  sudo iptables -w 5 -L "$chain_name" -n -v --line-numbers
  sudo ip6tables -w 5 -L "$chain6_name" -n -v --line-numbers
  echo "Проверьте доступ с разрешённого IP до завершения текущей SSH-сессии."
}

list_ispmanager_access() {
  local chain_name="ISPMGR_ACCESS"
  local chain6_name="ISPMGR6_ACCESS"

  echo -e "${CYAN}=== Доступ к ISPmanager ===${RESET}"

  if sudo iptables -w 5 -nL "$chain_name" >/dev/null 2>&1; then
    echo "Управляемая цепочка $chain_name:"
    sudo iptables -w 5 -L "$chain_name" -n -v --line-numbers
  else
    echo "Управляемая цепочка $chain_name пока не создана."
  fi

  echo
  echo "Прямые правила INPUT для TCP-порта 1500:"
  if ! sudo iptables -w 5 -S INPUT | grep -E -- '--dport 1500'; then
    echo "Прямые правила отсутствуют."
  fi

  echo
  echo "Ограничение IPv6 для TCP-порта 1500:"
  if sudo ip6tables -w 5 -nL "$chain6_name" >/dev/null 2>&1; then
    sudo ip6tables -w 5 -L "$chain6_name" -n -v --line-numbers
  else
    echo -e "${YELLOW}Управляемая IPv6-цепочка отсутствует.${RESET}"
  fi
}

add_ispmanager_allowed_ip() {
  local chain_name="ISPMGR_ACCESS"
  local detected_ip=""
  local allowed_ip
  local confirmation
  local firewall_backup

  if ! sudo iptables -w 5 -nL "$chain_name" >/dev/null 2>&1; then
    echo -e "${RED}Сначала создайте ограничение через пункт 2 меню iptables.${RESET}"
    return 1
  fi

  if [[ -n "${SSH_CLIENT:-}" ]]; then
    detected_ip="${SSH_CLIENT%% *}"
  fi

  read -rp "Введите разрешённый IPv4-адрес${detected_ip:+ [по умолчанию: $detected_ip]}: " allowed_ip
  if [[ -z "$allowed_ip" && -n "$detected_ip" ]]; then
    allowed_ip="$detected_ip"
  fi

  if ! is_valid_ipv4 "$allowed_ip"; then
    echo -e "${RED}Некорректный IPv4-адрес: $allowed_ip.${RESET}"
    return 1
  fi

  if sudo iptables -w 5 -C "$chain_name" -s "$allowed_ip/32" -j ACCEPT >/dev/null 2>&1; then
    echo "Адрес $allowed_ip уже присутствует в управляемом allowlist."
    return 0
  fi

  show_command_plan_header
  show_command sudo iptables -w 5 -I "$chain_name" 1 -s "$allowed_ip/32" -j ACCEPT
  show_command sudo netfilter-persistent save
  read -rp "Разрешить доступ к ISPmanager с $allowed_ip? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена."
    return 0
  fi

  firewall_backup=$(backup_firewall_rules) || {
    echo -e "${RED}Не удалось создать резервную копию правил. Изменения отменены.${RESET}"
    return 1
  }
  echo "Резервная копия фаервола: $firewall_backup"

  # Разрешающее правило вставляется перед завершающим DROP.
  run_command sudo iptables -w 5 -I "$chain_name" 1 -s "$allowed_ip/32" -j ACCEPT || {
    restore_firewall_rules "$firewall_backup"
    return 1
  }

  if ! setup_iptables_persistence; then
    echo -e "${RED}Не удалось сохранить правила. Отменяем добавление адреса.${RESET}"
    restore_firewall_rules "$firewall_backup"
    return 1
  fi

  echo -e "${GREEN}Доступ с $allowed_ip разрешён.${RESET}"
  list_ispmanager_access
}

remove_ispmanager_allowed_ip() {
  local chain_name="ISPMGR_ACCESS"
  local allowed_ip
  local confirmation
  local managed_rule_exists=0
  local legacy_rule_exists=0
  local managed_rule_count=0
  local firewall_backup

  list_ispmanager_access
  echo
  read -rp "Введите IPv4-адрес, доступ которого нужно удалить: " allowed_ip

  if ! is_valid_ipv4 "$allowed_ip"; then
    echo -e "${RED}Некорректный IPv4-адрес: $allowed_ip.${RESET}"
    return 1
  fi

  if sudo iptables -w 5 -nL "$chain_name" >/dev/null 2>&1; then
    managed_rule_count=$(sudo iptables -w 5 -S "$chain_name" |
      grep -c -- '-j ACCEPT' || true)

    if sudo iptables -w 5 -C "$chain_name" -s "$allowed_ip/32" -j ACCEPT >/dev/null 2>&1; then
      managed_rule_exists=1
    fi
  fi

  # Поддерживаем удаление старых правил, созданных до появления ISPMGR_ACCESS.
  if sudo iptables -w 5 -C INPUT -s "$allowed_ip/32" -p tcp --dport 1500 -j ACCEPT >/dev/null 2>&1; then
    legacy_rule_exists=1
  fi

  if ((managed_rule_exists == 0 && legacy_rule_exists == 0)); then
    echo "Разрешающие правила для $allowed_ip не найдены."
    return 0
  fi

  if ((managed_rule_exists == 1 && managed_rule_count <= 1)); then
    echo -e "${RED}Нельзя удалить последний адрес из управляемого allowlist.${RESET}"
    echo "Сначала добавьте новый разрешённый IP."
    return 1
  fi

  show_command_plan_header
  if ((managed_rule_exists == 1)); then
    show_command sudo iptables -w 5 -D "$chain_name" -s "$allowed_ip/32" -j ACCEPT
  fi
  if ((legacy_rule_exists == 1)); then
    show_command sudo iptables -w 5 -D INPUT -s "$allowed_ip/32" -p tcp --dport 1500 -j ACCEPT
  fi
  show_command sudo netfilter-persistent save
  read -rp "Удалить доступ к ISPmanager для $allowed_ip? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена."
    return 0
  fi

  firewall_backup=$(backup_firewall_rules) || {
    echo -e "${RED}Не удалось создать резервную копию правил. Изменения отменены.${RESET}"
    return 1
  }
  echo "Резервная копия фаервола: $firewall_backup"

  while sudo iptables -w 5 -C "$chain_name" -s "$allowed_ip/32" -j ACCEPT >/dev/null 2>&1; do
    run_command sudo iptables -w 5 -D "$chain_name" -s "$allowed_ip/32" -j ACCEPT || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  done

  while sudo iptables -w 5 -C INPUT -s "$allowed_ip/32" -p tcp --dport 1500 -j ACCEPT >/dev/null 2>&1; do
    run_command sudo iptables -w 5 -D INPUT -s "$allowed_ip/32" -p tcp --dport 1500 -j ACCEPT || {
      restore_firewall_rules "$firewall_backup"
      return 1
    }
  done

  if ! setup_iptables_persistence; then
    echo -e "${RED}Не удалось сохранить правила. Отменяем удаление адреса.${RESET}"
    restore_firewall_rules "$firewall_backup"
    return 1
  fi

  echo -e "${GREEN}Доступ для $allowed_ip удалён.${RESET}"
  list_ispmanager_access
}

######### Docker ########

docker_status() {
  echo -e "${CYAN}=== Состояние Docker ===${RESET}"

  if command -v docker >/dev/null 2>&1; then
    show_command docker --version
    docker --version
    show_command docker compose version
    docker compose version || true
  else
    echo "Docker не установлен."
  fi

  if systemd_unit_exists docker.service; then
    show_command sudo systemctl status docker --no-pager
    sudo systemctl status docker --no-pager || true
  else
    echo "Служба docker.service не найдена."
  fi
}

install_docker() {
  local confirmation

  show_command_plan_header
  show_command sudo apt-get update
  show_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2
  show_command sudo systemctl enable --now docker
  read -rp "Установить или обновить Docker и Docker Compose v2? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Пакеты и служба Docker не изменены."
    return 0
  fi

  run_command sudo apt-get update || return 1
  run_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 || return 1
  run_command sudo systemctl enable --now docker || return 1
  sudo systemctl is-active --quiet docker || {
    echo -e "${RED}Служба Docker не запущена.${RESET}"
    return 1
  }

  docker_status
}

upgrade_docker() {
  local confirmation
  local -a docker_packages=("docker.io")

  if ! dpkg-query -W -f='${Status}' docker.io 2>/dev/null | grep -q '^install ok installed$'; then
    echo -e "${RED}Пакет docker.io не установлен. Сначала выполните установку Docker.${RESET}"
    return 1
  fi

  if dpkg-query -W -f='${Status}' docker-compose-v2 2>/dev/null | grep -q '^install ok installed$'; then
    docker_packages+=("docker-compose-v2")
  fi

  show_command_plan_header
  show_command sudo apt-get update
  show_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "${docker_packages[@]}"
  read -rp "Обновить установленные пакеты Docker до доступных пакетных версий? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Пакеты Docker не изменены."
    return 0
  fi

  run_command sudo apt-get update || return 1
  run_command sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "${docker_packages[@]}" || return 1
  echo "Автоматический перезапуск Docker не выполнялся, чтобы не прерывать работающие контейнеры."
  docker_status
}

configure_docker_user_access() {
  local username
  local add_docker
  local add_sudo
  local confirmation

  read -rp "Введите имя существующего пользователя: " username
  if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || ! getent passwd "$username" >/dev/null; then
    echo -e "${RED}Пользователь $username не найден или его имя недопустимо.${RESET}"
    return 1
  fi

  if ! getent group docker >/dev/null; then
    echo -e "${RED}Группа docker не найдена. Сначала установите Docker.${RESET}"
    return 1
  fi

  echo -e "${YELLOW}Членство в группе docker позволяет управлять контейнерами и фактически даёт привилегии уровня root.${RESET}"
  read -rp "Добавить пользователя $username в группу docker? [y/N]: " add_docker
  read -rp "Добавить пользователя $username в группу sudo? [y/N]: " add_sudo

  if [[ ! "$add_docker" =~ ^[YyДд]$ && ! "$add_sudo" =~ ^[YyДд]$ ]]; then
    echo "Операция отменена. Группы пользователя не изменены."
    return 0
  fi

  show_command_plan_header
  if [[ "$add_docker" =~ ^[YyДд]$ ]]; then
    show_command sudo usermod -aG docker "$username"
  fi
  if [[ "$add_sudo" =~ ^[YyДд]$ ]]; then
    show_command sudo usermod -aG sudo "$username"
  fi
  show_command id "$username"

  read -rp "Для применения указанных изменений введите точное имя пользователя '$username': " confirmation
  if [[ "$confirmation" != "$username" ]]; then
    echo "Подтверждение не получено. Группы пользователя не изменены."
    return 0
  fi

  if [[ "$add_docker" =~ ^[YyДд]$ ]]; then
    run_command sudo usermod -aG docker "$username" || return 1
  fi
  if [[ "$add_sudo" =~ ^[YyДд]$ ]]; then
    run_command sudo usermod -aG sudo "$username" || return 1
  fi

  show_command id "$username"
  id "$username"
  echo "Новые группы начнут действовать после повторного входа пользователя в систему."
}

docker_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Docker ===${RESET}"
    echo "1. Проверить Docker, Compose и состояние службы"
    echo "2. Установить Docker и Docker Compose v2"
    echo "3. Обновить установленные пакеты Docker"
    echo "4. Настроить доступ пользователя к Docker и sudo"
    echo "0. Назад в главное меню"
    echo
    read -rp "Выберите действие: " CHOICE

    case $CHOICE in
      1) docker_status ;;
      2) install_docker ;;
      3) upgrade_docker ;;
      4) configure_docker_user_access ;;
      0) break ;;
      *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Подменю iptables
iptables_menu() {
  while true; do
    echo
    echo -e "${CYAN}=== Фаервол iptables ===${RESET}"
    echo "1. Список правил iptables"
    echo "2. Ограничить доступ к ISPmanager по IP"
    echo "3. Показать доступ к ISPmanager"
    echo "4. Добавить разрешённый IP для ISPmanager"
    echo "5. Удалить разрешённый IP для ISPmanager"
    echo "6. Проверить сохранение правил после перезагрузки"
    echo "0. Назад в главное меню"
    echo
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
    1) rules_iptables ;;
    2) restrict_ispmanager_access ;;
    3) list_ispmanager_access ;;
    4) add_ispmanager_allowed_ip ;;
    5) remove_ispmanager_allowed_ip ;;
    6) check_iptables_persistence ;;
    0) break ;;
    *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
    esac
  done
}

# Главное меню
while true; do
  echo
  echo "=== Главное меню ==="
  echo "1. Система"
  echo "2. SSH"
  echo "3. Fail2Ban"
  echo "4. Пользователи"
  echo "5. Nginx"
  echo "6. Сеть"
  echo "7. Фаервол iptables"
  echo "8. Аудит безопасности без изменений"
  echo "9. Автоматические обновления безопасности"
  echo "10. Инвентаризация и отключение служб"
  echo "11. Проверка файловой системы"
  echo "12. Сохранить итоговый отчёт безопасности"
  echo "13. Docker"
  echo "14. Logwatch"
  echo "15. GoAccess"
  echo "0. Выход"
  echo
  read -p "Введите номер раздела: " MAIN_CHOICE

  case $MAIN_CHOICE in
  1) system_menu ;;
  2) ssh_settings_menu ;;
  3) fail2ban_settings_menu ;;
  4) user_settings_menu ;;
  5) nginx_menu ;;
  6) network_menu ;;
  7) iptables_menu ;;
  8) security_audit ;;
  9) security_updates_menu ;;
  10) services_security_menu ;;
  11) filesystem_security_audit ;;
  12) save_security_report ;;
  13) docker_menu ;;
  14) logwatch_menu ;;
  15) goaccess_menu ;;
  0)
    echo "Выход."
    exit 0
    ;;
  *) echo "Неверный выбор. Пожалуйста, попробуйте снова." ;;
  esac
done
