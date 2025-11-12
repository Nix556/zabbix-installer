#!/bin/bash
source lib/colors.sh

confirm "Are you sure you want to remove Zabbix and all its data?" || exit 0

info "Stopping Zabbix services..."
sudo systemctl stop zabbix-server zabbix-agent apache2

info "Removing packages..."
sudo apt purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent apache2 mariadb-server mariadb-client php*

info "Removing Zabbix files..."
sudo rm -rf /etc/zabbix /usr/share/zabbix /var/log/zabbix /var/lib/mysql

success "Zabbix fully removed."
