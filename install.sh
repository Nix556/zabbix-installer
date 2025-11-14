#!/bin/bash
# Zabbix 7.4 Installer for Debian 12

# Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

# -----------------------------
# Functions
# -----------------------------
info() { echo -e "${GREEN}[INFO] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# -----------------------------
# Detect OS
# -----------------------------
info "Detecting OS..."
OS=$(lsb_release -si)
VER=$(lsb_release -sr)
if [[ "$OS" != "Debian" || "$VER" != "12" ]]; then
    error "This script only supports Debian 12"
fi
info "OS detected: Debian $VER"

# -----------------------------
# User input
# -----------------------------
read -rp "Enter Zabbix Server IP [127.0.0.1]: " ZBX_IP
ZBX_IP=${ZBX_IP:-127.0.0.1}

read -rp "Enter Zabbix DB name [zabbix]: " ZBX_DB
ZBX_DB=${ZBX_DB:-zabbix}

read -rp "Enter Zabbix DB user [zabbix]: " ZBX_USER
ZBX_USER=${ZBX_USER:-zabbix}

read -rsp "Enter Zabbix DB password: " ZBX_PASS
echo
read -rsp "Enter MariaDB root password: " ROOT_PASS
echo
read -rp "Enter Zabbix Admin password (frontend) [zabbix]: " ZBX_ADMIN_PASS
ZBX_ADMIN_PASS=${ZBX_ADMIN_PASS:-zabbix}

info "Configuration summary:
  DB: $ZBX_DB / $ZBX_USER
  Zabbix IP: $ZBX_IP
  Frontend Admin password: $ZBX_ADMIN_PASS"

# -----------------------------
# Install required packages
# -----------------------------
info "Installing required packages..."
apt update
DEPS=(wget curl gnupg2 lsb-release jq apt-transport-https php php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip php-curl mariadb-server mariadb-client rsync socat ssl-cert fping snmpd apache2)
apt install -y "${DEPS[@]}"

# -----------------------------
# Add Zabbix repository
# -----------------------------
info "Adding Zabbix repository..."
ZBX_DEB="https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb"
wget -O /tmp/zabbix-release.deb "$ZBX_DEB"
dpkg -i /tmp/zabbix-release.deb
apt update

# -----------------------------
# Install Zabbix packages
# -----------------------------
info "Installing Zabbix packages..."
ZBX_PKGS=(zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent)
apt install -y "${ZBX_PKGS[@]}"

# -----------------------------
# Configure MariaDB
# -----------------------------
info "Configuring MariaDB..."
mysql -uroot -p"$ROOT_PASS" <<EOF
CREATE DATABASE IF NOT EXISTS $ZBX_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$ZBX_USER'@'localhost' IDENTIFIED BY '$ZBX_PASS';
GRANT ALL PRIVILEGES ON $ZBX_DB.* TO '$ZBX_USER'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EOF

# -----------------------------
# Import Zabbix schema
# -----------------------------
info "Importing initial Zabbix schema..."
SCHEMA="/usr/share/zabbix-sql-scripts/mysql/server.sql.gz"
if [[ ! -f "$SCHEMA" ]]; then
    error "Zabbix SQL schema file not found: $SCHEMA"
fi
zcat "$SCHEMA" | mysql -u"$ZBX_USER" -p"$ZBX_PASS" "$ZBX_DB"

# -----------------------------
# Reset log_bin_trust_function_creators
# -----------------------------
mysql -uroot -p"$ROOT_PASS" -e "SET GLOBAL log_bin_trust_function_creators = 0;"

# -----------------------------
# Configure Zabbix server
# -----------------------------
info "Configuring Zabbix server..."
sed -i "s/# DBPassword=/DBPassword=$ZBX_PASS/" /etc/zabbix/zabbix_server.conf

# -----------------------------
# Configure Zabbix agent
# -----------------------------
info "Configuring Zabbix agent..."
sed -i "s/Server=127.0.0.1/Server=$ZBX_IP/" /etc/zabbix/zabbix_agentd.conf
sed -i "s/ServerActive=127.0.0.1/ServerActive=$ZBX_IP/" /etc/zabbix/zabbix_agentd.conf
sed -i "s/Hostname=Zabbix server/Hostname=$ZBX_IP/" /etc/zabbix/zabbix_agentd.conf

# -----------------------------
# Set PHP timezone
# -----------------------------
info "Setting PHP timezone..."
PHP_INI="/etc/php/8.2/apache2/php.ini"
sed -i "s#;date.timezone =#date.timezone = UTC#" "$PHP_INI"

# -----------------------------
# Enable Apache Zabbix frontend
# -----------------------------
info "Enabling Apache Zabbix frontend..."
a2enconf zabbix
if ! systemctl is-active --quiet apache2; then
    systemctl start apache2
fi
systemctl reload apache2

# -----------------------------
# Start services
# -----------------------------
info "Starting Zabbix server and agent..."
systemctl enable zabbix-server zabbix-agent apache2
systemctl restart zabbix-server zabbix-agent apache2

info "Zabbix installation completed!"
info "Access the frontend at: http://$ZBX_IP/zabbix"
info "Use '$ZBX_ADMIN_PASS' as the Admin password."
