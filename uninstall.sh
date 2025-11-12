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

info "This will completely remove Zabbix and all related data."
if ! confirm "Are you sure you want to proceed?"; then
    warning "Uninstallation cancelled."
    exit 0
fi

info "Stopping Zabbix services..."
{
    sudo systemctl stop zabbix-server zabbix-agent apache2
} & spinner
success "Services stopped"

info "Removing Zabbix packages..."
{
    sudo apt purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
    zabbix-sql-scripts zabbix-agent apache2 mariadb-server mariadb-client php* >/dev/null
} & spinner
success "Packages removed"

info "Removing Zabbix configuration files and logs..."
{
    sudo rm -rf /etc/zabbix /usr/share/zabbix /var/log/zabbix
} & spinner
success "Configuration files and logs removed"

info "Dropping Zabbix database..."
{
    read -rp "Enter MariaDB root password to drop Zabbix DB: " ROOT_PASS
    sudo mysql -uroot -p"$ROOT_PASS" -e "DROP DATABASE IF EXISTS zabbix; DROP USER IF EXISTS 'zabbix'@'localhost';"
} & spinner
success "Database and user removed"

info "Removing Zabbix API config..."
{
    rm -rf config/zabbix_api.conf
} & spinner
success "API configuration removed"

success "Zabbix fully uninstalled!"
