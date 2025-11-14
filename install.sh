#!/bin/bash
# Zabbix 7.4 installer for Debian 12 and Ubuntu 22.04

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

set -euo pipefail
IFS=$'\n\t'

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${GREEN}[INFO] Detecting OS...${NC}"
OS=$(lsb_release -si)
VER=$(lsb_release -sr)

# Set correct Zabbix repo URL based on OS
if [[ "$OS" == "Debian" && "$VER" == "12"* ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/debian/pool/main/z/zabbix-release/zabbix-release_7.4-1+debian12_all.deb"
elif [[ "$OS" == "Ubuntu" && "$VER" == "22.04"* ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.4-1+ubuntu22.04_all.deb"
else
    echo -e "${RED}[ERROR] Only Debian 12 and Ubuntu 22.04 are supported.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] OS detected: $OS $VER${NC}"

# --- USER INPUT ---
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

# --- INSTALL PREREQUISITES ---
echo -e "${GREEN}[INFO] Installing required packages...${NC}"
apt update -y
apt install -y wget curl gnupg2 lsb-release jq apt-transport-https \
php php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip php-curl \
mariadb-server mariadb-client rsync socat ssl-cert fping snmpd

# --- ADD ZABBIX REPO ---
echo -e "${GREEN}[INFO] Adding Zabbix repository...${NC}"
wget -qO /tmp/zabbix-release.deb "$REPO_URL"
dpkg -i /tmp/zabbix-release.deb
apt update -y

# --- PRE-CREATE ZABBIX AGENT CONFIG (required before installing agent) ---
AGENT_CONF="/etc/zabbix/zabbix_agentd.conf"
mkdir -p /etc/zabbix
if [[ ! -f "$AGENT_CONF" ]]; then
    echo -e "${YELLOW}[INFO] Creating default Zabbix Agent config...${NC}"
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

# --- INSTALL ZABBIX SERVER, FRONTEND, AGENT ---
echo -e "${GREEN}[INFO] Installing Zabbix server, frontend, and agent...${NC}"
DEBIAN_FRONTEND=noninteractive apt install -y \
    zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent

# --- CONFIGURE DATABASE ---
echo -e "${GREEN}[INFO] Configuring MariaDB...${NC}"
mysql -uroot -p"$ROOT_PASS" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SET GLOBAL log_bin_trust_function_creators = 1;
EOF

echo -e "${GREEN}[INFO] Importing initial Zabbix schema...${NC}"
zcat /usr/share/doc/zabbix-server-mysql/create.sql.gz | mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"

# Disable log_bin_trust_function_creators after import
mysql -uroot -p"$ROOT_PASS" -e "SET GLOBAL log_bin_trust_function_creators = 0;"

# --- CONFIGURE ZABBIX SERVER ---
sed -i "s|^# DBPassword=.*|DBPassword=$DB_PASS|" /etc/zabbix/zabbix_server.conf

# --- CONFIGURE PHP TIMEZONE ---
PHP_INI=$(php --ini | grep "Loaded Configuration" | awk -F: '{print $2}' | xargs)
if [[ -f "$PHP_INI" ]]; then
    sed -i "s|^;*date.timezone =.*|date.timezone = UTC|" "$PHP_INI"
fi

# --- CREATE FRONTEND CONFIG ---
FRONTEND_CONF="/etc/zabbix/web/zabbix.conf.php"
mkdir -p "$(dirname "$FRONTEND_CONF")"
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

# --- ENABLE AND START SERVICES ---
echo -e "${GREEN}[INFO] Starting and enabling services...${NC}"
systemctl enable zabbix-server zabbix-agent apache2
systemctl restart apache2
systemctl restart zabbix-server
systemctl restart zabbix-agent

# --- VERIFY AGENT STATUS ---
echo -e "${GREEN}[INFO] Checking Zabbix Agent status...${NC}"
if systemctl is-active --quiet zabbix-agent; then
    echo -e "${GREEN}[OK] Zabbix Agent running.${NC}"
else
    echo -e "${RED}[ERROR] Zabbix Agent failed to start. Check logs with:"
    echo "  journalctl -xeu zabbix-agent"
fi

echo -e "${GREEN}[OK] Zabbix installation complete!${NC}"
echo "Access frontend at: http://$ZABBIX_IP/zabbix"
echo "Username: Admin"
echo "Password: $ZABBIX_ADMIN_PASS"
