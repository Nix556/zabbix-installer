#!/bin/bash
set -e
source lib/colors.sh
source lib/utils.sh
source lib/system.sh

spinner() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
}

run_with_spinner() { "$@" & spinner; }

info "This will completely remove Zabbix and all related data."
if ! confirm "Are you sure you want to proceed?"; then
    warning "Uninstallation cancelled."
    exit 0
fi

info "Stopping Zabbix services..."
run_with_spinner sudo systemctl stop zabbix-server zabbix-agent apache2
success "Services stopped ✅"

info "Removing Zabbix packages..."
run_with_spinner sudo apt purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
    zabbix-sql-scripts zabbix-agent apache2 mariadb-server mariadb-client php* >/dev/null
success "Packages removed ✅"

info "Removing configuration files and logs..."
run_with_spinner sudo rm -rf /etc/zabbix /usr/share/zabbix /var/log/zabbix
success "Configs and logs removed ✅"

if [[ -f /etc/zabbix/zabbix_server.conf ]]; then
    DB_NAME=$(grep "^DBName=" /etc/zabbix/zabbix_server.conf | cut -d= -f2)
    DB_USER=$(grep "^DBUser=" /etc/zabbix/zabbix_server.conf | cut -d= -f2)
else
    DB_NAME="zabbix"
    DB_USER="zabbix"
    warning "Could not detect DB info, using defaults: $DB_NAME / $DB_USER"
fi

info "Dropping Zabbix database ($DB_NAME) and user ($DB_USER)..."
read -rp "Enter MariaDB root password: " ROOT_PASS
run_with_spinner sudo mysql -uroot -p"$ROOT_PASS" -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; DROP USER IF EXISTS '$DB_USER'@'localhost';"
success "Database and user removed ✅"

info "Removing API config..."
run_with_spinner rm -rf config/zabbix_api.conf
success "API config removed ✅"

success "Zabbix fully uninstalled!"
