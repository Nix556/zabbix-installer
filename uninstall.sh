#!/bin/bash
# Zabbix full uninstall script for Debian 12 / Ubuntu 22.04
# Deletes Zabbix server, agent, frontend, database, and configs

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin
set -euo pipefail
IFS=$'\n\t'

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

# show a progress animation with dots while a command runs
wait_spinner() {
    local pid=$!
    local delay=0.5
    local dots=""
    printf "Please wait"
    while kill -0 $pid 2>/dev/null; do
        dots="${dots}."
        if [[ ${#dots} -gt 3 ]]; then
            dots=""
        fi
        printf "\rPlease wait%-3s" "$dots"
        sleep $delay
    done
    printf "\r%-30s\r" ""  # clear line after command finishes
}

echo -e "${YELLOW}[WARNING] This will completely remove Zabbix server, agent, frontend, and database!${NC}"
read -rp "Are you sure you want to uninstall Zabbix? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${GREEN}[INFO] Uninstallation cancelled.${NC}"
    exit 0
fi

# ask for MariaDB root password
while true; do
    read -rsp "Enter MariaDB root password: " ROOT_PASS
    echo
    [[ -n "$ROOT_PASS" ]] && break
done

# ask for database name to drop
read -rp "Enter the Zabbix database name to remove [zabbix]: " DB_NAME
DB_NAME=${DB_NAME:-zabbix}

# stop services
echo -e "${GREEN}[INFO] stopping Zabbix and Apache services...${NC}"
systemctl stop zabbix-server zabbix-agent apache2 & wait_spinner
echo -e "${GREEN}[OK] services stopped${NC}"

# remove packages
echo -e "${GREEN}[INFO] removing Zabbix packages...${NC}"
apt purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent & wait_spinner
echo -e "${GREEN}[OK] Zabbix packages removed${NC}"

# remove remaining configs and frontend
echo -e "${GREEN}[INFO] removing configuration files and frontend...${NC}"
rm -rf /etc/zabbix /usr/share/zabbix /etc/apache2/conf-available/zabbix.conf /etc/apache2/conf-enabled/zabbix.conf & wait_spinner
echo -e "${GREEN}[OK] configuration files removed${NC}"

# drop database
echo -e "${GREEN}[INFO] dropping Zabbix database...${NC}"
mysql -uroot -p"$ROOT_PASS" <<EOF & wait_spinner
DROP DATABASE IF EXISTS $DB_NAME;
DROP USER IF EXISTS 'zabbix'@'localhost';
FLUSH PRIVILEGES;
EOF
echo -e "${GREEN}[OK] database dropped${NC}"

# autoremove unused packages
echo -e "${GREEN}[INFO] cleaning up unused packages...${NC}"
apt autoremove -y & wait_spinner
echo -e "${GREEN}[OK] cleanup complete${NC}"

echo -e "${GREEN}[OK] Zabbix uninstallation finished!${NC}"
