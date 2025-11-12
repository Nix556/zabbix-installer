#!/bin/bash

set -e

source lib/colors.sh
source lib/utils.sh
source lib/system.sh
source lib/db.sh

detect_os
update_system

DB_NAME=$(ask "Enter Zabbix DB name: " "zabbix")
DB_USER=$(ask "Enter Zabbix DB user: " "zabbix")
DB_PASS=$(ask "Enter Zabbix DB password: " "zabbix123")
ROOT_PASS=$(ask "Enter MariaDB root password: " "")
ZABBIX_IP=$(ask "Enter Zabbix Server IP: " "127.0.0.1")
ZABBIX_ADMIN_PASS=$(ask "Enter Zabbix Admin password (frontend): " "zabbix")

info "Your configuration:"
echo "DB: $DB_NAME / $DB_USER"
echo "Zabbix IP: $ZABBIX_IP"
echo "Zabbix Admin password: $ZABBIX_ADMIN_PASS"

info "Installing required packages..."
sudo $PM install -y wget curl gnupg2 software-properties-common lsb-release \
apache2 mariadb-server mariadb-client php8.2 php8.2-mysql php8.2-gd \
php8.2-bcmath php8.2-mbstring php8.2-xml php8.2-ldap php8.2-curl jq

info "Adding Zabbix 7.4 repository..."
wget https://repo.zabbix.com/zabbix/7.4/${OS}/$(lsb_release -cs)/amd64/zabbix-release_7.4-1+${OS}$(lsb_release -rs)_all.deb
sudo dpkg -i zabbix-release_7.4-1+${OS}$(lsb_release -rs)_all.deb
sudo $PM update -y

info "Installing Zabbix server, frontend, agent..."
sudo $PM install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

create_zabbix_db "$DB_NAME" "$DB_USER" "$DB_PASS" "$ROOT_PASS"

info "Importing initial schema..."
zcat /usr/share/doc/zabbix-sql-scripts/mysql/create.sql.gz | mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"

info "Configuring Zabbix server..."
sudo sed -i "s/^DBName=.*/DBName=$DB_NAME/" /etc/zabbix/zabbix_server.conf
sudo sed -i "s/^DBUser=.*/DBUser=$DB_USER/" /etc/zabbix/zabbix_server.conf
sudo sed -i "s/^# DBPassword=.*/DBPassword=$DB_PASS/" /etc/zabbix/zabbix_server.conf

info "Enabling and starting services..."
sudo systemctl enable --now zabbix-server zabbix-agent apache2

info "Setting Zabbix Admin password..."
sudo mysql -uroot -p"$ROOT_PASS" "$DB_NAME" -e "UPDATE users SET passwd=MD5('$ZABBIX_ADMIN_PASS') WHERE alias='Admin';"

info "Generating Zabbix API configuration..."
mkdir -p config
cat > config/zabbix_api.conf <<EOF
# Zabbix API configuration
ZABBIX_URL="http://$ZABBIX_IP/zabbix"
ZABBIX_USER="Admin"
ZABBIX_PASS="$ZABBIX_ADMIN_PASS"
EOF

success "Zabbix API config generated at config/zabbix_api.conf"

success "Zabbix 7.4 installation complete!"
echo "Access frontend at: http://$ZABBIX_IP/zabbix"
echo "Zabbix Admin user: Admin"
echo "Zabbix Admin password: $ZABBIX_ADMIN_PASS"
