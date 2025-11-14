#!/bin/bash
# zabbix 7.4 installer for Debian 12 / Ubuntu 22.04
# fully interactive, agent config compatible with directory-based setup

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
    printf "Installing... please wait"
    while kill -0 $pid 2>/dev/null; do
        dots="${dots}."
        if [[ ${#dots} -gt 3 ]]; then
            dots=""
        fi
        printf "\rInstalling... please wait%-3s" "$dots"
        sleep $delay
    done
    printf "\r%-30s\r" ""  # clear line after command finishes
}

echo -e "${GREEN}[INFO] detecting OS...${NC}"
OS=$(lsb_release -si)
VER=$(lsb_release -sr)

if [[ "$OS" == "Debian" && "$VER" == "12"* ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb"
elif [[ "$OS" == "Ubuntu" && "$VER" == "22.04"* ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.4+ubuntu22.04_all.deb"
else
    echo -e "${RED}[ERROR] only Debian 12 and Ubuntu 22.04 are supported.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] OS detected: $OS $VER${NC}"

# user input
read -rp "enter Zabbix Server IP [127.0.0.1]: " ZABBIX_IP
ZABBIX_IP=${ZABBIX_IP:-127.0.0.1}

read -rp "enter Zabbix DB name [zabbix]: " DB_NAME
DB_NAME=${DB_NAME:-zabbix}

read -rp "enter Zabbix DB user [zabbix]: " DB_USER
DB_USER=${DB_USER:-zabbix}

while true; do
    read -rsp "enter Zabbix DB password: " DB_PASS
    echo
    [[ -n "$DB_PASS" ]] && break
done

while true; do
    read -rsp "enter MariaDB root password: " ROOT_PASS
    echo
    [[ -n "$ROOT_PASS" ]] && break
done

read -rp "enter Zabbix Admin password (frontend) [zabbix]: " ZABBIX_ADMIN_PASS
ZABBIX_ADMIN_PASS=${ZABBIX_ADMIN_PASS:-zabbix}

echo -e "${GREEN}[INFO] configuration summary:${NC}"
echo "  DB: $DB_NAME / $DB_USER"
echo "  Zabbix IP: $ZABBIX_IP"
echo "  Frontend Admin password: $ZABBIX_ADMIN_PASS"

# install prerequisites
echo -e "${GREEN}[INFO] installing required packages...${NC}"
apt update -y & wait_spinner
echo -e "${GREEN}[OK] package list updated${NC}"

apt install -y wget curl gnupg2 lsb-release jq apt-transport-https \
php php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip php-curl \
mariadb-server mariadb-client rsync socat ssl-cert fping snmpd apache2 & wait_spinner
echo -e "${GREEN}[OK] prerequisites installed${NC}"

# add zabbix repo
echo -e "${GREEN}[INFO] adding Zabbix repository...${NC}"
wget -qO /tmp/zabbix-release.deb "$REPO_URL" & wait_spinner
dpkg -i /tmp/zabbix-release.deb & wait_spinner
apt update -y & wait_spinner
echo -e "${GREEN}[OK] Zabbix repository added${NC}"

# install zabbix server, frontend, agent
echo -e "${GREEN}[INFO] installing Zabbix packages...${NC}"
DEBIAN_FRONTEND=noninteractive apt install -y \
    zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent & wait_spinner
echo -e "${GREEN}[OK] Zabbix packages installed${NC}"

# configure database
echo -e "${GREEN}[INFO] configuring MariaDB...${NC}"
mysql -uroot -p"$ROOT_PASS" <<EOF & wait_spinner
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
echo -e "${GREEN}[OK] MariaDB configured${NC}"

echo -e "${GREEN}[INFO] importing initial Zabbix schema...${NC}"
zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" & wait_spinner
echo -e "${GREEN}[OK] Zabbix schema imported${NC}"

# configure zabbix server
echo -e "${GREEN}[INFO] configuring Zabbix server...${NC}"
sed -i "s|^# DBPassword=.*|DBPassword=$DB_PASS|" /etc/zabbix/zabbix_server.conf
echo -e "${GREEN}[OK] Zabbix server configured${NC}"

# configure zabbix agent using directory-based config
echo -e "${GREEN}[INFO] configuring Zabbix agent...${NC}"
mkdir -p /etc/zabbix/zabbix_agentd.d
cat > /etc/zabbix/zabbix_agentd.d/agent.conf <<EOF
Server=$ZABBIX_IP
ServerActive=$ZABBIX_IP
Hostname=$(hostname)
EOF
chown root:root /etc/zabbix/zabbix_agentd.d/agent.conf
chmod 644 /etc/zabbix/zabbix_agentd.d/agent.conf
echo -e "${GREEN}[OK] Zabbix agent configured${NC}"

# configure php timezone
echo -e "${GREEN}[INFO] setting PHP timezone...${NC}"
PHP_INI=$(php --ini | grep "Loaded Configuration" | awk -F: '{print $2}' | xargs)
[[ -f "$PHP_INI" ]] && sed -i "s|^;*date.timezone =.*|date.timezone = UTC|" "$PHP_INI"
echo -e "${GREEN}[OK] PHP timezone set${NC}"

# create frontend config
echo -e "${GREEN}[INFO] creating frontend configuration...${NC}"
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
echo -e "${GREEN}[OK] frontend configuration created${NC}"

# enable apache zabbix config
echo -e "${GREEN}[INFO] enabling apache Zabbix frontend...${NC}"
if command -v a2enconf >/dev/null 2>&1; then
    a2enconf zabbix & wait_spinner
else
    ln -sf /etc/apache2/conf-available/zabbix.conf /etc/apache2/conf-enabled/zabbix.conf
fi
systemctl reload apache2
echo -e "${GREEN}[OK] apache Zabbix frontend enabled${NC}"

# enable and start services
echo -e "${GREEN}[INFO] starting and enabling services...${NC}"
systemctl daemon-reload
systemctl restart zabbix-server zabbix-agent apache2 & wait_spinner
systemctl enable zabbix-server zabbix-agent apache2
echo -e "${GREEN}[OK] services started and enabled${NC}"

# verify agent status
echo -e "${GREEN}[INFO] checking Zabbix Agent status...${NC}"
if systemctl is-active --quiet zabbix-agent; then
    echo -e "${GREEN}[OK] Zabbix Agent is running.${NC}"
else
    echo -e "${RED}[ERROR] Zabbix Agent failed to start.${NC}"
    echo "Check logs with: journalctl -xeu zabbix-agent"
fi

# cleanup temporary files and packages
echo -e "${GREEN}[INFO] cleaning up temporary files...${NC}"
rm -f /tmp/zabbix-release.deb
apt autoremove -y & wait_spinner
echo -e "${GREEN}[OK] cleanup complete${NC}"

echo -e "${GREEN}[OK] Zabbix installation complete!${NC}"
echo "Access frontend at: http://$ZABBIX_IP/zabbix"
echo "Username: Admin"
echo "Password: $ZABBIX_ADMIN_PASS"
