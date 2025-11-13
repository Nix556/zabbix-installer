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
apt install -y wget curl gnupg2 lsb-release jq apt-transport-https \
mariadb-server apache2 php php-mysql php-xml php-bcmath php-mbstring \
php-ldap php-json php-gd php-zip php-curl zabbix-sql-scripts snmpd fping libsnmp40

echo -e "${GREEN}[OK] Prerequisites installed${NC}"

echo -e "${GREEN}[INFO] Adding Zabbix 7.4 repository...${NC}"
ZABBIX_DEB="/tmp/zabbix-release.deb"
wget -qO "$ZABBIX_DEB" "https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb"
dpkg -i "$ZABBIX_DEB"
apt update -y
echo -e "${GREEN}[OK] Zabbix repository added${NC}"

echo -e "${GREEN}[INFO] Installing Zabbix server, frontend, and agent...${NC}"
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent

echo -e "${GREEN}[OK] Zabbix installed${NC}"

# --- Ensure root can login with password ---
mysql_root_auth=$(mysql -u root -e "SELECT 1;" 2>/dev/null || true)
if [[ -z "$mysql_root_auth" ]]; then
    echo -e "${GREEN}[INFO] Setting MariaDB root password authentication...${NC}"
    sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_ROOT_PASS'; FLUSH PRIVILEGES;"
    echo -e "${GREEN}[OK] MariaDB root password set${NC}"
fi

echo -e "${GREEN}[INFO] Creating Zabbix database and user...${NC}"
mysql -u root -p"$DB_ROOT_PASS" <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS $ZABBIX_DB_NAME character set utf8mb4 collate utf8mb4_bin;
CREATE USER IF NOT EXISTS '$ZABBIX_DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_DB_PASS';
GRANT ALL PRIVILEGES ON $ZABBIX_DB_NAME.* TO '$ZABBIX_DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo -e "${GREEN}[OK] Database created${NC}"

echo -e "${GREEN}[INFO] Importing initial schema...${NC}"

SQL_DIRS=(
    "/usr/share/zabbix/sql-scripts/mysql"
    "/usr/share/doc/zabbix-sql-scripts/mysql"
)

FOUND=0
for DIR in "${SQL_DIRS[@]}"; do
    if [[ -d "$DIR" ]]; then
        for FILE in server.sql.gz images.sql.gz data.sql.gz; do
            if [[ -f "$DIR/$FILE" ]]; then
                echo -e "${GREEN}[INFO] Importing $FILE ...${NC}"
                zcat "$DIR/$FILE" | mysql --default-character-set=utf8mb4 -u"$ZABBIX_DB_USER" -p"$ZABBIX_DB_PASS" "$ZABBIX_DB_NAME"
                FOUND=1
            fi
        done
    fi
done

if [[ $FOUND -eq 0 ]]; then
    echo -e "${YELLOW}[WARN] No schema files found, skipping import.${NC}"
else
    echo -e "${GREEN}[OK] Schema imported${NC}"
fi

sed -i "s/^DBPassword=.*/DBPassword=$ZABBIX_DB_PASS/" /etc/zabbix/zabbix_server.conf

# --- Automatic PHP timezone detection and update ---
echo -e "${GREEN}[INFO] Configuring PHP timezone for Apache...${NC}"

PHP_INI=$(php --ini | grep "Loaded Configuration" | awk -F: '{print $2}' | xargs)

if [[ -f "$PHP_INI" ]]; then
    if ! grep -q "^date.timezone" "$PHP_INI"; then
        echo "date.timezone = UTC" >> "$PHP_INI"
    else
        sed -i "s|^date.timezone.*|date.timezone = UTC|" "$PHP_INI"
    fi
    echo -e "${GREEN}[OK] PHP timezone set to UTC in $PHP_INI${NC}"
else
    echo -e "${YELLOW}[WARN] PHP configuration file not found, timezone not set.${NC}"
fi

# --- Automatic creation of zabbix.conf.php ---
echo -e "${GREEN}[INFO] Creating Zabbix frontend configuration...${NC}"
FRONTEND_CONF="/etc/zabbix/web/zabbix.conf.php"

cat > "$FRONTEND_CONF" <<EOF
<?php
\$DB['TYPE']     = 'MYSQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = '$ZABBIX_DB_NAME';
\$DB['USER']     = '$ZABBIX_DB_USER';
\$DB['PASSWORD'] = '$ZABBIX_DB_PASS';
\$ZBX_SERVER     = '$ZABBIX_IP';
\$ZBX_SERVER_PORT= '10051';
\$ZBX_SERVER_NAME= 'Zabbix Server';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
EOF

chown www-data:www-data "$FRONTEND_CONF"
chmod 640 "$FRONTEND_CONF"
echo -e "${GREEN}[OK] Zabbix frontend configuration created at $FRONTEND_CONF${NC}"

# --- Ensure minimal Zabbix agent config exists for Debian 12 ---
AGENT_CONF_DIR="/etc/zabbix/zabbix_agentd.d"
AGENT_MAIN_CONF="$AGENT_CONF_DIR/zabbix_agentd.conf"

if [[ ! -f "$AGENT_MAIN_CONF" ]]; then
    echo -e "${GREEN}[INFO] Creating minimal Zabbix agent config...${NC}"
    cat > "$AGENT_MAIN_CONF" <<EOF
PidFile=/run/zabbix/zabbix_agentd.pid
LogFile=/var/log/zabbix/zabbix_agentd.log
Server=$ZABBIX_IP
ServerActive=$ZABBIX_IP
Hostname=$(hostname)
Include=/etc/zabbix/zabbix_agentd.d/*.conf
EOF
    chown root:root "$AGENT_MAIN_CONF"
    chmod 644 "$AGENT_MAIN_CONF"
    echo -e "${GREEN}[OK] Zabbix agent config created at $AGENT_MAIN_CONF${NC}"
fi

# Reload Apache and enable services
echo -e "${GREEN}[INFO] Enabling and starting services...${NC}"
systemctl enable zabbix-server zabbix-agent apache2
systemctl restart apache2
systemctl restart zabbix-agent
systemctl start zabbix-server

echo -e "${GREEN}[OK] Zabbix server and agent started. Apache reloaded.${NC}"
echo -e "${GREEN}[INFO] Installation complete! Access frontend at http://$ZABBIX_IP/zabbix${NC}"
echo "Login: Admin / $ZABBIX_ADMIN_PASS"
