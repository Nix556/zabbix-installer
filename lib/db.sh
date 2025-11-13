#!/bin/bash

create_zabbix_db() {
    local DB_NAME="$1"
    local DB_USER="$2"
    local DB_PASS="$3"
    local ROOT_PASS="$4"

    if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" || -z "$ROOT_PASS" ]]; then
        echo "[ERROR] Missing arguments for create_zabbix_db"
        return 1
    fi

    echo "[INFO] Creating Zabbix database and user..."
    mysql_cmd="CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; \
               CREATE USER IF NOT EXISTS '\`$DB_USER\`'@'localhost' IDENTIFIED BY '$DB_PASS'; \
               GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '\`$DB_USER\`'@'localhost'; \
               FLUSH PRIVILEGES;"

    if [[ $EUID -eq 0 ]]; then
        mysql -u root -p"$ROOT_PASS" -e "$mysql_cmd"
    else
        sudo mysql -u root -p"$ROOT_PASS" -e "$mysql_cmd"
    fi
}

drop_zabbix_db() {
    local DB_NAME="$1"
    local DB_USER="$2"
    local ROOT_PASS="$3"

    if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$ROOT_PASS" ]]; then
        echo "[ERROR] Missing arguments for drop_zabbix_db"
        return 1
    fi

    echo "[INFO] Dropping Zabbix database and user..."
    mysql_cmd="DROP DATABASE IF EXISTS \`$DB_NAME\`; \
               DROP USER IF EXISTS '\`$DB_USER\`'@'localhost';"

    if [[ $EUID -eq 0 ]]; then
        mysql -u root -p"$ROOT_PASS" -e "$mysql_cmd"
    else
        sudo mysql -u root -p"$ROOT_PASS" -e "$mysql_cmd"
    fi
}
