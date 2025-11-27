#!/bin/bash
# zabbix 7.4 installer for Debian 12 / Ubuntu 22.04
# fully interactive, agent config compatible with directory-based setup
# automatically enables apache zabbix frontend

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin
set -euo pipefail
IFS=$'\n\t'

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] please run as root (sudo).${NC}"
    exit 1
fi
export DEBIAN_FRONTEND=noninteractive

echo -e "${GREEN}[INFO] detecting OS...${NC}"
. /etc/os-release
OS="$ID"
VER="$VERSION_ID"

if [[ "$OS" == "debian" && "$VER" == "12" ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb"
elif [[ "$OS" == "ubuntu" && "$VER" == "22.04" ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.4+ubuntu22.04_all.deb"
else
    echo -e "${RED}[ERROR] only Debian 12 and Ubuntu 22.04 are supported.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] OS detected: ${PRETTY_NAME}${NC}"

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
    read -rsp "enter MariaDB root password (leave empty if using socket auth): " ROOT_PASS
    echo
    break
done

read -rp "enter Zabbix Admin password (frontend) [zabbix]: " ZABBIX_ADMIN_PASS
ZABBIX_ADMIN_PASS=${ZABBIX_ADMIN_PASS:-zabbix}

echo -e "${GREEN}[INFO] configuration summary:${NC}"
echo "  DB: $DB_NAME / $DB_USER"
echo "  Zabbix IP: $ZABBIX_IP"
echo "  Frontend Admin password: $ZABBIX_ADMIN_PASS"

if command -v php >/dev/null 2>&1; then
    PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
else
    case "${OS}-${VER}" in
        debian-12) PHP_VER="8.2" ;;
        ubuntu-22.04) PHP_VER="8.1" ;;
        *) PHP_VER="8.2" ;;
    esac
fi

# Create runtime directories (but NOT config files - let packages create those)
mkdir -p /run/php 2>/dev/null || true

echo -e "${GREEN}[INFO] installing required packages...${NC}"
apt update -y

# Pre-create directories that packages expect (fixes reinstall issues)
mkdir -p /var/lib/snmp /etc/snmp
chown -R Debian-snmp:Debian-snmp /var/lib/snmp 2>/dev/null || true

# Remove stale PHP module ini files that block reinstall
if [[ -d /etc/php ]]; then
    find /etc/php -name "*.ini" -size 0 -delete 2>/dev/null || true
fi

PKGS=(wget curl gnupg2 jq apt-transport-https
      php-cli php-fpm php-mysql php-xml php-bcmath php-mbstring php-ldap php-gd php-zip php-curl
      mariadb-server mariadb-client rsync socat ssl-cert fping snmpd apache2)

set +e
# Fix any broken packages first
dpkg --configure -a 2>/dev/null || true
apt --fix-broken install -y 2>/dev/null || true

# Use dpkg options to auto-accept package maintainer config files (prevents interactive prompts)
apt -o APT::Install-Recommends=false -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" install -y "${PKGS[@]}"
APT_STATUS=$?
if (( APT_STATUS != 0 )); then
    echo -e "${YELLOW}[WARN] retrying fix-broken...${NC}"
    # Ensure snmpd directories exist
    mkdir -p /var/lib/snmp /etc/snmp
    chown -R Debian-snmp:Debian-snmp /var/lib/snmp 2>/dev/null || true
    dpkg --configure -a 2>/dev/null || true
    apt --fix-broken install -y
    apt -o APT::Install-Recommends=false -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" install -y "${PKGS[@]}"
fi
set -e

echo -e "${GREEN}[INFO] adding Zabbix repository...${NC}"
wget -qO /tmp/zabbix-release.deb "$REPO_URL"
dpkg -i /tmp/zabbix-release.deb
apt update -y

echo -e "${GREEN}[INFO] installing Zabbix packages...${NC}"
apt -o APT::Install-Recommends=false -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" install -y \
    zabbix-server-mysql zabbix-frontend-php zabbix-sql-scripts zabbix-agent

apt -y purge 'libapache2-mod-php*' || true
dpkg --configure -a || true
apt --fix-broken install -y || true

if command -v a2enmod >/dev/null 2>&1; then
    a2enmod mpm_event proxy proxy_fcgi setenvif alias || true
fi

if [[ -d /usr/share/zabbix/ui ]]; then
    ZABBIX_UI_DIR="/usr/share/zabbix/ui"
else
    ZABBIX_UI_DIR="/usr/share/zabbix"
fi

ZABBIX_APACHE_CONF="/etc/apache2/conf-available/zabbix.conf"
cat > "$ZABBIX_APACHE_CONF" <<EOF
Alias /zabbix $ZABBIX_UI_DIR

<Directory "$ZABBIX_UI_DIR">
    Options FollowSymLinks
    AllowOverride None
    Require all granted
    DirectoryIndex index.php
</Directory>

<IfModule proxy_fcgi_module>
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost/"
    </FilesMatch>
</IfModule>
EOF

if command -v a2enconf >/dev/null 2>&1; then
    a2enconf zabbix || ln -sf /etc/apache2/conf-available/zabbix.conf /etc/apache2/conf-enabled/zabbix.conf || true
fi

cat > /etc/apache2/conf-available/zabbix-override.conf <<EOF
<Directory $ZABBIX_UI_DIR>
    Options FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
EOF

a2enconf zabbix-override

systemctl enable --now apache2 || true
systemctl enable --now "php${PHP_VER}-fpm" || true
systemctl restart apache2 || systemctl reload apache2 || true

echo -e "${GREEN}[INFO] configuring MariaDB...${NC}"

systemctl enable --now mariadb || systemctl enable --now mysql || true

for i in {1..30}; do
    [[ -S /run/mysqld/mysqld.sock ]] && break
    sleep 1
done

MYSQL_ROOT_ARGS=(-uroot)
[[ -n "${ROOT_PASS:-}" ]] && MYSQL_ROOT_ARGS+=(-p"$ROOT_PASS")

mysql "${MYSQL_ROOT_ARGS[@]}" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

echo -e "${GREEN}[INFO] importing initial Zabbix schema (if needed)...${NC}"
if ! mysql "${MYSQL_ROOT_ARGS[@]}" -Nse "SELECT 1 FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name='users' LIMIT 1;" | grep -q 1; then
    zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
else
    echo -e "${YELLOW}[SKIP] schema already exists.${NC}"
fi

echo -e "${GREEN}[INFO] configuring Zabbix server...${NC}"
sed -i "s|^#\? DBName=.*|DBName=$DB_NAME|" /etc/zabbix/zabbix_server.conf
sed -i "s|^#\? DBUser=.*|DBUser=$DB_USER|" /etc/zabbix/zabbix_server.conf
sed -i "s|^#\? DBPassword=.*|DBPassword=$DB_PASS|" /etc/zabbix/zabbix_server.conf
sed -i '/^[[:space:]]*#\?\s*DBType=/Id' /etc/zabbix/zabbix_server.conf || true

echo -e "${GREEN}[INFO] configuring Zabbix agent...${NC}"
mkdir -p /etc/zabbix/zabbix_agentd.d
cat > /etc/zabbix/zabbix_agentd.d/agent.conf <<EOF
Server=$ZABBIX_IP
ServerActive=$ZABBIX_IP
Hostname=$(hostname)
EOF

echo -e "${GREEN}[INFO] setting PHP timezone and performance settings...${NC}"
for SAPI in fpm cli; do
    PHP_INI="/etc/php/${PHP_VER}/${SAPI}/php.ini"
    if [[ -f "$PHP_INI" ]]; then
        sed -i "s|^;*date.timezone =.*|date.timezone = UTC|" "$PHP_INI" || true
        sed -i "s|^;*post_max_size =.*|post_max_size = 16M|" "$PHP_INI" || true
        sed -i "s|^;*max_execution_time =.*|max_execution_time = 300|" "$PHP_INI" || true
        sed -i "s|^;*max_input_time =.*|max_input_time = 300|" "$PHP_INI" || true
        sed -i "s|^;*memory_limit =.*|memory_limit = 128M|" "$PHP_INI" || true
        sed -i "s|^;*upload_max_filesize =.*|upload_max_filesize = 2M|" "$PHP_INI" || true
    fi
done

ensure_php_exts() {
    local exts=(mysqli pdo_mysql)
    for ext in "${exts[@]}"; do
        local mod_ini="/etc/php/${PHP_VER}/mods-available/${ext}.ini"
        [[ -f "$mod_ini" ]] || echo "extension=${ext}" > "$mod_ini"
        for sapi in fpm cli apache2; do
            local d="/etc/php/${PHP_VER}/${sapi}/conf.d"
            [[ -d "$d" ]] || continue
            ln -sf "$mod_ini" "$d/20-${ext}.ini"
        done
    done
}
ensure_php_exts

systemctl restart "php${PHP_VER}-fpm" || true

echo -e "${GREEN}[INFO] creating frontend configuration...${NC}"
FRONTEND_CONF="/etc/zabbix/web/zabbix.conf.php"
mkdir -p /etc/zabbix/web
cat > "$FRONTEND_CONF" <<EOF
<?php
\$DB['TYPE']     = 'MYSQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = '$DB_NAME';
\$DB['USER']     = '$DB_USER';
\$DB['PASSWORD'] = '$DB_PASS';
\$DB['SCHEMA']   = '';
\$DB['ENCRYPTION'] = false;
\$DB['KEY_FILE'] = '';
\$DB['CERT_FILE'] = '';
\$DB['CA_FILE'] = '';
\$DB['VERIFY_HOST'] = false;
\$DB['CIPHER_LIST'] = '';
\$DB['VAULT'] = '';
\$DB['VAULT_URL'] = '';
\$DB['VAULT_PREFIX'] = '';
\$DB['VAULT_DB_PATH'] = '';
\$DB['VAULT_TOKEN'] = '';
\$DB['VAULT_CERT_FILE'] = '';
\$DB['VAULT_KEY_FILE'] = '';
\$DB['DOUBLE_IEEE754'] = true;
\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = 'Zabbix Server';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
?>
EOF

echo -e "${GREEN}[INFO] cleaning up...${NC}"
rm -f /tmp/zabbix-release.deb
apt autoremove -y

echo -e "${GREEN}[INFO] starting and enabling Zabbix services...${NC}"
systemctl enable zabbix-server zabbix-agent || true
systemctl restart zabbix-server zabbix-agent || true
systemctl restart "php${PHP_VER}-fpm" || true
systemctl restart apache2 || true

# Wait for Zabbix server to start
echo -e "${GREEN}[INFO] waiting for Zabbix server to start...${NC}"
for i in {1..30}; do
    if systemctl is-active --quiet zabbix-server; then
        echo -e "${GREEN}[OK] Zabbix server is running.${NC}"
        break
    fi
    sleep 1
done

if ! systemctl is-active --quiet zabbix-server; then
    echo -e "${YELLOW}[WARN] Zabbix server may not have started. Check: systemctl status zabbix-server${NC}"
fi

echo -e "${GREEN}[OK] Zabbix installation complete!${NC}"
echo "Access frontend at: http://$ZABBIX_IP/zabbix"
echo "Username: Admin"
echo "Password: $ZABBIX_ADMIN_PASS"