#!/bin/bash
# Zabbix 7.4 Installer (Debian 12 / Ubuntu 22.04)

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

set -euo pipefail
IFS=$'\n\t'

# Colors 
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${GREEN}[INFO] Detecting OS...${NC}"
OS=$(lsb_release -si)
VER=$(lsb_release -sr)

if [[ "$OS" == "Debian" && "$VER" == "12"* ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb"
elif [[ "$OS" == "Ubuntu" && "$VER" == "22.04"* ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.4+ubuntu22.04_all.deb"
else
    echo -e "${RED}[ERROR] Only Debian 12 or Ubuntu 22.04 are supported.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] OS detected:${NC} $OS $VER"

# User input
echo -e "${YELLOW}[SETUP] Enter configuration details:${NC}"
read -rp "Zabbix Server IP [127.0.0.1]: " ZABBIX_IP
ZABBIX_IP=${ZABBIX_IP:-127.0.0.1}
read -rp "Database name [zabbix]: " DB_NAME
DB_NAME=${DB_NAME:-zabbix}
read -rp "Database user [zabbix]: " DB_USER
DB_USER=${DB_USER:-zabbix}
while true; do read -rsp "Database password: " DB_PASS; echo; [[ -n "$DB_PASS" ]] && break; done
while true; do read -rsp "MariaDB root password: " ROOT_PASS; echo; [[ -n "$ROOT_PASS" ]] && break; done
read -rp "Frontend Admin password [zabbix]: " ZABBIX_ADMIN_PASS
ZABBIX_ADMIN_PASS=${ZABBIX_ADMIN_PASS:-zabbix}

echo -e "${GREEN}[INFO] Summary:${NC}"
echo "  DB: $DB_NAME / $DB_USER"
echo "  Server IP: $ZABBIX_IP"
echo "  Frontend Admin password: $ZABBIX_ADMIN_PASS"
sleep 2

# Dependencies
echo -e "${GREEN}[STEP] Installing dependencies...${NC}"
apt update -y
apt install -y wget curl gnupg2 lsb-release jq apt-transport-https \
php php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip php-curl \
mariadb-server mariadb-client rsync socat ssl-cert fping snmpd

# Repo
echo -e "${GREEN}[STEP] Adding Zabbix repository...${NC}"
wget -qO /tmp/zabbix-release.deb "$REPO_URL"
dpkg -i /tmp/zabbix-release.deb
apt update -y

# Install Zabbix
echo -e "${GREEN}[STEP] Installing Zabbix server, frontend, and agent...${NC}"
DEBIAN_FRONTEND=noninteractive apt install -y \
    zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

# Agent config fix
AGENT_CONF="/etc/zabbix/zabbix_agentd.conf"
if [[ ! -f "$AGENT_CONF" ]]; then
    echo -e "${YELLOW}[WARN] Agent config missing, creating default...${NC}"
    mkdir -p /etc/zabbix
    cat > "$AGENT_CONF" <<EOF
PidFile=/run/zabbix/zabbix_agentd.pid
LogFile=/var/log/zabbix/zabbix_agentd.log
LogFileSize=0
Server=$ZABBIX_IP
ServerActive=$ZABBIX_IP
Hostname=$(hostname)
Include=/etc/zabbix/zabbix_agentd.d/*.conf
EOF
fi
chown root:root "$AGENT_CONF"
chmod 644 "$AGENT_CONF"

# Database setup 
echo -e "${GREEN}[STEP] Configuring MariaDB...${NC}"
mysql -uroot -p"$ROOT_PASS" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SET GLOBAL log_bin_trust_function_creators = 1;
EOF

echo -e "${GREEN}[STEP] Importing Zabbix schema...${NC}"
zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | \
mysql --default-character-set=utf8mb4 -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"

mysql -uroot -p"$ROOT_PASS" -e "SET GLOBAL log_bin_trust_function_creators = 0;"

# Zabbix server config
echo -e "${GREEN}[STEP] Configuring Zabbix server...${NC}"
sed -i "s|^# DBPassword=.*|DBPassword=$DB_PASS|" /etc/zabbix/zabbix_server.conf

# PHP timezone 
echo -e "${GREEN}[STEP] Setting PHP timezone...${NC}"
PHP_INI=$(php --ini | grep "Loaded Configuration" | awk -F: '{print $2}' | xargs)
if [[ -f "$PHP_INI" ]]; then
    sed -i "s|^;*date.timezone =.*|date.timezone = UTC|" "$PHP_INI"
fi

# Frontend config
echo -e "${GREEN}[STEP] Writing frontend config...${NC}"
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

# Enable services 
echo -e "${GREEN}[STEP] Enabling and starting services...${NC}"
systemctl enable zabbix-server zabbix-agent apache2
systemctl restart apache2 zabbix-server zabbix-agent

# Verify 
if systemctl is-active --quiet zabbix-agent; then
    echo -e "${GREEN}[OK] Zabbix Agent running.${NC}"
else
    echo -e "${RED}[ERROR] Zabbix Agent failed. Check logs with:${NC} journalctl -xeu zabbix-agent"
fi

echo -e "${GREEN}[DONE] Zabbix installation complete!${NC}"
echo "Access frontend: http://$ZABBIX_IP/zabbix"
echo "Login: Admin / $ZABBIX_ADMIN_PASS"
