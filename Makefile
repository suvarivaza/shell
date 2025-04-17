# Загружаем переменные из .env

ifneq (,$(wildcard .env))
    include .env
    export
endif

server = "$(SSH_USER)@$(SSH_IP)"

ssh-connect: ## connect to server by ssh
	ssh -t $(server) "cd $(REMOTE_PATH_SITE); bash"

#=== FILES ===# ## Для работы с файлами

download-archive: ## download archive tar.gz by ssh
	ssh $(server) 'cd $(REMOTE_PATH_SITE) && tar $(EXCLUDE_PATH)  -vczf - ./' > site.tar.gz

unzip-archive: ## unzip archive tar.gz
	tar -xvf site.tar.gz -C ./$(LOCAL_PATH_SITE)

download-files: ## download archive gzip by ssh and unzip immediately
	ssh $(server) 'cd $(REMOTE_PATH_SITE) && tar $(EXCLUDE_PATH) -vczf - ./' | tar  xzf -

download-folder: ## download files from specific dir by ssh: make download-folder folder=storage/ai_images
	ssh $(server) 'cd $(REMOTE_PATH_SITE) && tar -vczf - $(folder)' | tar  xzf -


#=== DATABASE ===# ## Для работы с базой

download-db: ## download db dump by ssh
	ssh $(server) "mysqldump -u $(DB_USER) -p $(DB_NAME) | gzip" > db.sql.gz
	gunzip db.sql.gz

download-db-dev:
	ssh $(server) "mysqldump -u $(DB_USER) -p $(DB_NAME) --where='true limit 100000' | gzip" > db.sql.gz
	gunzip db.sql.gz

import-db:
	ssh $(server) "mysql -u $(DB_USER) -p $(DB_NAME) < db.sql"



#=== SERVICE COMMANDS ===# ## Сервисные команды (предварительно нужно подключится к серверу: make ssh-connect)

read-server-errors-logs: ## read log file
	cat $(PATH_ERROR_LOG) | sort | uniq -c | sort -nr | head -n 15

read-server-errors-logs-real-time: ## read file in realtime
	tail -f -n 10 -s 1 $(PATH_ERROR_LOG)

find-file: ## find file by name
	find . -name "fileName"

search-string-in-files: ## find string in files: make search-string-in-files string=need_string
	grep -r $(string) /var/log/

show-top-ip: ## показать топ IP адресов с большим количеством запросов (first do: make ssh-connect)
	grep "19/Aug/2023:02" $(PATH_ACCESS_LOG) | awk "{print $1}" | sort | uniq -c | sort -nr | head -n 10

show-count-requests: ## показать топ IP адресов с большим количеством запросов
	grep -c "19/Aug/2023:02" $(PATH_ACCESS_LOG)

show-changes-in-php-files: ## показать изменения в php файлах за последние n минут: make show-changes-in-php-files n=60
	find $(REMOTE_PATH_SITE) -type f -mmin -$(n) -iname '*.php*'

show-changes-in-files: ## показать изменения во всех файлах за последние n минут: make show-changes-in-files n=60
	find $(REMOTE_PATH_SITE) -type f -mmin -$(n)

count-files:
	ssh $(server) 'find ai_images/ -type f -mtime +5 | wc'

biggest-files:
	ssh $(server) 'find ai_images/ -type f -exec du -Sh {} + | sort -rh | head -n 5'

memory-size:
	ssh $(server) 'du -h'

show-top-ip:
	ssh $(server) 'grep "19/Aug/2023:02" $(PATH_ACCESS_LOG) | awk "{print $1}" | sort | uniq -c | sort -nr | head -n 10'

show-count-requests:
	ssh $(server) 'grep -c "19/Aug/2023:02" $(PATH_ACCESS_LOG)'

#============= HELP ===============#
.PHONY: help
help:
	@echo ======= Help =======
	@egrep -h '^[^[:blank:]].*\s##\s' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help