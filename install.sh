#!/bin/bash
# Zabbix 7.4 installer using lib scripts
# Debian 12 / Ubuntu 22.04

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/db.sh"
source "$SCRIPT_DIR/lib/system.sh"

# Detect OS
detect_os
if [[ "$OS_NAME" == "Debian" && "$OS_VERSION" != "12" ]] && [[ "$OS_NAME" == "Ubuntu" && "$OS_VERSION" != "22.04" ]]; then
    error "Only Debian 12 and Ubuntu 22.04 are supported."
    exit 1
fi

# Set Zabbix repo URL
if [[ "$OS_NAME" == "Debian" ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb"
else
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.4+ubuntu22.04_all.deb"
fi

# User inputs
ZABBIX_IP=$(ask "Enter Zabbix Server IP" "127.0.0.1")
until validate_ip "$ZABBIX_IP"; do
    warn "Invalid IP address. Try again."
    ZABBIX_IP=$(ask "Enter Zabbix Server IP" "127.0.0.1")
done

DB_NAME=$(ask "Enter Zabbix DB name" "zabbix")
DB_USER=$(ask "Enter Zabbix DB user" "zabbix")

while true; do
    read -rsp "Enter Zabbix DB password: " DB_PASS
    echo
    [[ -n "$DB_PASS" ]] && break
done

while true; do
    read -rsp "Enter MariaDB root password: " ROOT_PASS
    echo
    [[ -n "$ROOT_PASS" ]] && break
done

ZABBIX_ADMIN_PASS=$(ask "Enter Zabbix Admin password (frontend)" "zabbix")

info "Installing required packages..."
update_system
apt install -y wget curl gnupg2 lsb-release jq apt-transport-https \
php php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip php-curl \
mariadb-server mariadb-client rsync socat ssl-cert fping snmpd apache2

# Add Zabbix repo
info "Adding Zabbix repository..."
wget -qO /tmp/zabbix-release.deb "$REPO_URL"
dpkg -i /tmp/zabbix-release.deb
apt update -y

# Install Zabbix packages
info "Installing Zabbix server, frontend, and agent..."
DEBIAN_FRONTEND=noninteractive apt install -y \
    zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent

# Configure database
create_zabbix_db "$DB_NAME" "$DB_USER" "$DB_PASS" "$ROOT_PASS"
info "Importing initial Zabbix schema..."
zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"

# Configure Zabbix server
sed -i "s|^# DBPassword=.*|DBPassword=$DB_PASS|" /etc/zabbix/zabbix_server.conf

# Configure Zabbix agent directory-based config
mkdir -p /etc/zabbix/zabbix_agentd.d
cat > /etc/zabbix/zabbix_agentd.d/agent.conf <<EOF
Server=$ZABBIX_IP
ServerActive=$ZABBIX_IP
Hostname=$(hostname)
EOF
chown root:root /etc/zabbix/zabbix_agentd.d/agent.conf
chmod 644 /etc/zabbix/zabbix_agentd.d/agent.conf

# PHP timezone
PHP_INI=$(php --ini | grep "Loaded Configuration" | awk -F: '{print $2}' | xargs)
[[ -f "$PHP_INI" ]] && sed -i "s|^;*date.timezone =.*|date.timezone = UTC|" "$PHP_INI"

# Frontend configuration
FRONTEND_CONF="/etc/zabbix/web/zabbix.conf.php"
cat > "$FRONTEND_CONF" <<EOF
<?php
\$DB['TYPE']     = 'MYSQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = '$DB_NAME';
\$DB['USER']     = '$DB_USER';
\$DB['PASSWORD'] = '$DB_PASS';
\$ZBX_SERVER     = '$ZABBIX_IP';
\$ZBX_SERVER_PORT= '10051';
\$ZBX_SERVER_NAME= 'Zabbix Server';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
EOF
chown www-data:www-data "$FRONTEND_CONF"
chmod 640 "$FRONTEND_CONF"

# Enable Apache Zabbix frontend
a2enconf zabbix || ln -sf /etc/apache2/conf-available/zabbix.conf /etc/apache2/conf-enabled/zabbix.conf
systemctl reload apache2

# Start services
start_service zabbix-server
start_service zabbix-agent
start_service apache2

success "Zabbix installation complete!"
echo "Access frontend at: http://$ZABBIX_IP/zabbix"
echo "Username: Admin"
echo "Password: $ZABBIX_ADMIN_PASS"
