#!/bin/bash
# Zabbix 7.4 installer for Debian 12 / Ubuntu 22.04
# Fully automated, includes MariaDB setup and frontend config

set -euo pipefail
IFS=$'\n\t'

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${GREEN}[INFO] Detecting OS...${NC}"
OS=$(lsb_release -si)
VER=$(lsb_release -sr)

if [[ "$OS" == "Debian" && "$VER" == 12* ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb"
elif [[ "$OS" == "Ubuntu" && "$VER" == 22.04* ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.4+ubuntu22.04_all.deb"
else
    echo -e "${RED}[ERROR] Only Debian 12 or Ubuntu 22.04 are supported.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] OS detected: $OS $VER${NC}"

# --- User input ---
read -rp "Enter Zabbix Server IP [127.0.0.1]: " ZABBIX_IP
ZABBIX_IP=${ZABBIX_IP:-127.0.0.1}

read -rp "Enter Zabbix DB name [zabbix]: " DB_NAME
DB_NAME=${DB_NAME:-zabbix}

read -rp "Enter Zabbix DB user [zabbix]: " DB_USER
DB_USER=${DB_USER:-zabbix}

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

read -rp "Enter Zabbix Admin password (frontend) [zabbix]: " ZABBIX_ADMIN_PASS
ZABBIX_ADMIN_PASS=${ZABBIX_ADMIN_PASS:-zabbix}

echo -e "${GREEN}[INFO] Configuration summary:${NC}"
echo "  DB: $DB_NAME / $DB_USER"
echo "  Zabbix IP: $ZABBIX_IP"
echo "  Frontend Admin password: $ZABBIX_ADMIN_PASS"

# --- Install prerequisites ---
echo -e "${GREEN}[INFO] Installing required packages...${NC}"
apt update -y
apt install -y wget curl gnupg2 lsb-release jq apt-transport-https \
php php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip php-curl \
mariadb-server mariadb-client rsync socat ssl-cert fping snmpd apache2

# --- Add Zabbix repo ---
echo -e "${GREEN}[INFO] Adding Zabbix repository...${NC}"
wget -qO /tmp/zabbix-release.deb "$REPO_URL"
dpkg -i /tmp/zabbix-release.deb
apt update -y

# --- Install Zabbix packages including SQL scripts ---
echo -e "${GREEN}[INFO] Installing Zabbix packages...${NC}"
DEBIAN_FRONTEND=noninteractive apt install -y \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-agent \
    zabbix-sql-scripts

# --- Configure MariaDB ---
echo -e "${GREEN}[INFO] Configuring MariaDB...${NC}"
mysql -uroot -p"$ROOT_PASS" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SET GLOBAL log_bin_trust_function_creators = 1;
EOF

# --- Import Zabbix schema ---
SQL_PATH="/usr/share/zabbix/sql-scripts/mysql/server.sql.gz"
if [[ ! -f "$SQL_PATH" ]]; then
    echo -e "${RED}[ERROR] Zabbix SQL schema file not found: $SQL_PATH${NC}"
    exit 1
fi
echo -e "${GREEN}[INFO] Importing initial Zabbix schema...${NC}"
zcat "$SQL_PATH" | mysql --default-character-set=utf8mb4 -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"

# Disable log_bin_trust_function_creators after import
mysql -uroot -p"$ROOT_PASS" -e "SET GLOBAL log_bin_trust_function_creators = 0;"

# --- Configure Zabbix server ---
echo -e "${GREEN}[INFO] Configuring Zabbix server...${NC}"
sed -i "s|^# DBPassword=.*|DBPassword=$DB_PASS|" /etc/zabbix/zabbix_server.conf

# --- Configure Zabbix agent ---
echo -e "${GREEN}[INFO] Configuring Zabbix agent...${NC}"
mkdir -p /etc/zabbix/zabbix_agentd.d
cat > /etc/zabbix/zabbix_agentd.d/agent.conf <<EOF
Server=$ZABBIX_IP
ServerActive=$ZABBIX_IP
Hostname=$(hostname)
EOF
chown root:root /etc/zabbix/zabbix_agentd.d/agent.conf
chmod 644 /etc/zabbix/zabbix_agentd.d/agent.conf

# --- Configure PHP timezone ---
echo -e "${GREEN}[INFO] Setting PHP timezone...${NC}"
PHP_INI=$(php --ini | grep "Loaded Configuration" | awk -F: '{print $2}' | xargs)
[[ -f "$PHP_INI" ]] && sed -i "s|^;*date.timezone =.*|date.timezone = UTC|" "$PHP_INI"

# --- Configure frontend ---
echo -e "${GREEN}[INFO] Creating frontend configuration...${NC}"
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

# --- Enable Apache Zabbix config ---
echo -e "${GREEN}[INFO] enabling apache Zabbix frontend...${NC}"
if command -v a2enconf >/dev/null 2>&1; then
    a2enconf zabbix
else
    ln -sf /etc/apache2/conf-available/zabbix.conf /etc/apache2/conf-enabled/zabbix.conf
fi

systemctl reload apache2

# --- Start and enable services ---
echo -e "${GREEN}[INFO] starting and enabling services...${NC}"
systemctl daemon-reload
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

# --- Verify agent status ---
echo -e "${GREEN}[INFO] Checking Zabbix Agent status...${NC}"
if systemctl is-active --quiet zabbix-agent; then
    echo -e "${GREEN}[OK] Zabbix Agent is running.${NC}"
else
    echo -e "${RED}[ERROR] Zabbix Agent failed to start.${NC}"
    echo "Check logs with: journalctl -xeu zabbix-agent"
fi

# --- Cleanup ---
echo -e "${GREEN}[INFO] Cleaning up temporary files...${NC}"
rm -f /tmp/zabbix-release.deb
apt autoremove -y

echo -e "${GREEN}[OK] Zabbix installation complete!${NC}"
echo "Access frontend at: http://$ZABBIX_IP/zabbix"
echo "Username: Admin"
echo "Password: $ZABBIX_ADMIN_PASS"
