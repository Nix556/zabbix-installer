#!/bin/bash
# Zabbix 7.4 installer for Debian 12
# Fully interactive: server IP, DB, passwords

set -e

echo "[INFO] Detecting OS..."
OS=$(lsb_release -si)
VER=$(lsb_release -sr)

if [[ "$OS" != "Debian" || "$VER" != "12"* ]]; then
    echo "[ERROR] This script is for Debian 12 only."
    exit 1
fi
echo "[OK] OS detected: Debian $VER"

# --- USER INPUT ---
read -rp "Enter Zabbix Server IP [127.0.0.1]: " ZABBIX_IP
ZABBIX_IP=${ZABBIX_IP:-127.0.0.1}

read -rp "Enter Zabbix DB name [zabbix]: " DB_NAME
DB_NAME=${DB_NAME:-zabbix}

read -rp "Enter Zabbix DB user [zabbix]: " DB_USER
DB_USER=${DB_USER:-zabbix}

read -rsp "Enter Zabbix DB password: " DB_PASS
echo
read -rsp "Enter MariaDB root password: " ROOT_PASS
echo
read -rp "Enter Zabbix Admin password (frontend) [zabbix]: " ZABBIX_ADMIN_PASS
ZABBIX_ADMIN_PASS=${ZABBIX_ADMIN_PASS:-zabbix}

echo "[INFO] Configuration summary:"
echo "DB: $DB_NAME / $DB_USER"
echo "Zabbix IP: $ZABBIX_IP"
echo "Zabbix Admin password: $ZABBIX_ADMIN_PASS"

# --- INSTALL PREREQUISITES ---
echo "[INFO] Installing required packages..."
apt update
apt install -y wget curl gnupg2 lsb-release jq apt-transport-https \
php php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip php-curl \
mariadb-server mariadb-client rsync socat ssl-cert fping snmpd

# --- ADD ZABBIX REPO ---
echo "[INFO] Adding Zabbix 7.4 repository..."
wget https://repo.zabbix.com/zabbix/7.4/debian/pool/main/z/zabbix-release/zabbix-release_7.4-1+debian12_all.deb -O /tmp/zabbix-release.deb
dpkg -i /tmp/zabbix-release.deb
apt update

# --- INSTALL ZABBIX SERVER, FRONTEND, AGENT ---
echo "[INFO] Installing Zabbix server, frontend, and agent..."
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-agent zabbix-apache-conf

# --- CONFIGURE ZABBIX DB ---
echo "[INFO] Configuring MariaDB..."
mysql -uroot -p"$ROOT_PASS" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# Import initial schema
zcat /usr/share/doc/zabbix-server-mysql/create.sql.gz | mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"

# --- CONFIGURE ZABBIX SERVER ---
sed -i "s/^# DBPassword=/DBPassword=$DB_PASS/" /etc/zabbix/zabbix_server.conf

# --- CONFIGURE ZABBIX AGENT ---
mkdir -p /etc/zabbix
cp /usr/share/doc/zabbix-agent/examples/zabbix_agentd.conf /etc/zabbix/zabbix_agentd.conf
sed -i "s/^Server=127.0.0.1/Server=$ZABBIX_IP/" /etc/zabbix/zabbix_agentd.conf
sed -i "s/^ServerActive=127.0.0.1/ServerActive=$ZABBIX_IP/" /etc/zabbix/zabbix_agentd.conf
chown root:root /etc/zabbix/zabbix_agentd.conf
chmod 644 /etc/zabbix/zabbix_agentd.conf

# --- ENABLE AND START SERVICES ---
systemctl enable zabbix-server zabbix-agent apache2
systemctl restart zabbix-server zabbix-agent apache2

echo "[OK] Zabbix installation complete!"
echo "Access frontend at: http://$ZABBIX_IP/zabbix"
echo "Username: Admin"
echo "Password: $ZABBIX_ADMIN_PASS"
