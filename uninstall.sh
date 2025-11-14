#!/bin/bash
# Zabbix 7.4 uninstaller for Debian 12 / Ubuntu 22.04
# Stops services, removes packages, configuration, and database

set -euo pipefail
IFS=$'\n\t'

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${YELLOW}[WARNING] This will completely remove Zabbix and its database!${NC}"
read -rp "Are you sure you want to continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${GREEN}[INFO] Uninstallation canceled.${NC}"
    exit 0
fi

# Stop services
echo -e "${GREEN}[INFO] stopping Zabbix and Apache services...${NC}"
systemctl stop zabbix-server zabbix-agent apache2 || true
systemctl disable zabbix-server zabbix-agent apache2 || true

# Ask for MariaDB root password
while true; do
    read -rsp "Enter MariaDB root password: " ROOT_PASS
    echo
    [[ -n "$ROOT_PASS" ]] && break
done

# Ask for database name to delete
read -rp "Enter Zabbix database name to delete [zabbix]: " DB_NAME
DB_NAME=${DB_NAME:-zabbix}

# Confirm database deletion
echo -e "${YELLOW}[WARNING] This will DROP the database '$DB_NAME'!${NC}"
read -rp "Are you sure? (yes/no): " DB_CONFIRM
if [[ "$DB_CONFIRM" == "yes" ]]; then
    echo -e "${GREEN}[INFO] dropping database '$DB_NAME'...${NC}"
    mysql -uroot -p"$ROOT_PASS" -e "DROP DATABASE IF EXISTS $DB_NAME;"
else
    echo -e "${GREEN}[INFO] Skipping database deletion.${NC}"
fi

# Remove Zabbix packages
echo -e "${GREEN}[INFO] removing Zabbix packages...${NC}"
DEBIAN_FRONTEND=noninteractive apt purge -y \
    zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent \
    zabbix-agent-mysql zabbix-sql-scripts

# Remove configuration files and directories
echo -e "${GREEN}[INFO] removing configuration files...${NC}"
rm -rf /etc/zabbix
rm -rf /usr/share/zabbix
rm -rf /var/log/zabbix
rm -rf /var/lib/zabbix

# Remove Zabbix repository package
echo -e "${GREEN}[INFO] removing Zabbix repository package...${NC}"
dpkg -r zabbix-release || true
rm -f /tmp/zabbix-release.deb

# Remove Apache Zabbix configuration
if [ -f /etc/apache2/conf-available/zabbix.conf ]; then
    a2disconf zabbix || true
    rm -f /etc/apache2/conf-available/zabbix.conf
fi

# Reload Apache
systemctl reload apache2 || true

# Cleanup packages
echo -e "${GREEN}[INFO] cleaning up unused packages...${NC}"
apt autoremove -y
apt update -y

echo -e "${GREEN}[OK] Zabbix uninstallation complete!${NC}"
