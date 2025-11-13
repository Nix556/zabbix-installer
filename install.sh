#!/bin/bash

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

set -euo pipefail
IFS=$'\n\t'

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${GREEN}[INFO] Detecting OS...${NC}"

OS_NAME=$(lsb_release -si)
OS_VER=$(lsb_release -sr)

if [[ "$OS_NAME" != "Debian" || "$OS_VER" != "12"* ]]; then
    echo -e "${RED}[ERROR] This script only supports Debian 12.${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] OS detected: Debian $OS_VER${NC}"

read -rp "Enter Zabbix Server IP [127.0.0.1]: " ZABBIX_IP
ZABBIX_IP=${ZABBIX_IP:-127.0.0.1}

read -rp "Enter Zabbix DB name [zabbix]: " ZABBIX_DB_NAME
ZABBIX_DB_NAME=${ZABBIX_DB_NAME:-zabbix}

read -rp "Enter Zabbix DB user [zabbix]: " ZABBIX_DB_USER
ZABBIX_DB_USER=${ZABBIX_DB_USER:-zabbix}

while true; do
    read -rsp "Enter Zabbix DB password: " ZABBIX_DB_PASS
    echo
    [[ -n "$ZABBIX_DB_PASS" ]] && break
    echo -e "${YELLOW}[WARN] Password cannot be empty${NC}"
done

while true; do
    read -rsp "Enter MariaDB root password: " DB_ROOT_PASS
    echo
    [[ -n "$DB_ROOT_PASS" ]] && break
    echo -e "${YELLOW}[WARN] Password cannot be empty${NC}"
done

read -rp "Enter Zabbix Admin password (frontend) [zabbix]: " ZABBIX_ADMIN_PASS
ZABBIX_ADMIN_PASS=${ZABBIX_ADMIN_PASS:-zabbix}

echo -e "${GREEN}[INFO] Configuration summary:${NC}"
echo "DB: $ZABBIX_DB_NAME / $ZABBIX_DB_USER"
echo "Zabbix IP: $ZABBIX_IP"
echo "Zabbix Admin password: $ZABBIX_ADMIN_PASS"

echo -e "${GREEN}[INFO] Installing required packages...${NC}"
apt update -y
apt install -y wget curl gnupg2 lsb-release jq apt-transport-https mariadb-server apache2 php php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip

echo -e "${GREEN}[OK] Prerequisites installed${NC}"

echo -e "${GREEN}[INFO] Adding Zabbix 7.4 repository...${NC}"
ZABBIX_DEB="/tmp/zabbix-release.deb"
wget -qO "$ZABBIX_DEB" "https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb"
dpkg -i "$ZABBIX_DEB"
apt update -y
echo -e "${GREEN}[OK] Zabbix repository added${NC}"

echo -e "${GREEN}[INFO] Installing Zabbix server, frontend, and agent...${NC}"
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent zabbix-sql-scripts snmpd fping libsnmp40 php-curl

echo -e "${GREEN}[OK] Zabbix installed${NC}"

echo -e "${GREEN}[INFO] Creating Zabbix database and user...${NC}"
mysql -u root -p"$DB_ROOT_PASS" <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS $ZABBIX_DB_NAME character set utf8mb4 collate utf8mb4_bin;
CREATE USER IF NOT EXISTS '$ZABBIX_DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_DB_PASS';
GRANT ALL PRIVILEGES ON $ZABBIX_DB_NAME.* TO '$ZABBIX_DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo -e "${GREEN}[OK] Database created${NC}"

echo -e "${GREEN}[INFO] Importing initial schema...${NC}"
zcat /usr/share/doc/zabbix-sql-scripts/mysql/server.sql.gz | mysql -u "$ZABBIX_DB_USER" -p"$ZABBIX_DB_PASS" "$ZABBIX_DB_NAME"
echo -e "${GREEN}[OK] Schema imported${NC}"

sed -i "s/^DBPassword=.*/DBPassword=$ZABBIX_DB_PASS/" /etc/zabbix/zabbix_server.conf

# Enable services
systemctl enable zabbix-server zabbix-agent apache2
systemctl start zabbix-server zabbix-agent
systemctl reload apache2

echo -e "${GREEN}[OK] Zabbix server and agent started. Apache reloaded.${NC}"
echo -e "${GREEN}[INFO] Installation complete! Access frontend at http://$ZABBIX_IP/zabbix${NC}"
echo "Login: Admin / $ZABBIX_ADMIN_PASS"
