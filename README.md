# Shell scripts

Набор вспомогательных скриптов для настройки, диагностики и обслуживания серверов.

## Документация

- [`server_setup.sh`](server_setup.sh) — интерактивная первичная настройка, аудит сервера и настройка внешних резервных копий Restic.
  - [Подробная документация Server Setup](SERVER_SETUP.md)

Для остальных скриптов отдельные документы будут добавляться по мере их аудита и обновления.

## Общий способ запуска

1. Скопировать скрипт на сервер.
2. Проверить его содержимое.
3. Сделать файл исполняемым, например:

```bash
chmod +x server_analysis.sh
```

4. Запустить:

```bash
./server_analysis.sh
./server_setup.sh
```

Или так:

```
bash <(wget -q -O- https://raw.githubusercontent.com/suvarivaza/shell/main/server_analysis.sh)
bash <(wget -q -O- https://raw.githubusercontent.com/suvarivaza/shell/main/server_setup.sh)
```

Запуск через удалённый URL менее безопасен: содержимое выполняется сразу и не проходит предварительную проверку.

## Полезные материалы

- [Awesome Bash](https://github.com/awesome-lists/awesome-bash)


