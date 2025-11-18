#!/bin/bash
# zabbix 7.4 installer for Debian 12 / Ubuntu 22.04
# fully interactive, agent config compatible with directory-based setup
# automatically enables apache zabbix frontend

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin
set -euo pipefail
IFS=$'\n\t'

# move colors before first usage
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

# require root and non-interactive apt
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] please run as root (sudo).${NC}"
    exit 1
fi
export DEBIAN_FRONTEND=noninteractive

echo -e "${GREEN}[INFO] detecting OS...${NC}"
# Use /etc/os-release to avoid relying on lsb_release
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

# Make MariaDB root password optional (socket auth on Debian/Ubuntu defaults)
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

# Determine target PHP version early (fallback by OS if php not installed yet)
if command -v php >/dev/null 2>&1; then
    PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
else
    case "${OS}-${VER}" in
        debian-12) PHP_VER="8.2" ;;
        ubuntu-22.04) PHP_VER="8.1" ;;
        *) PHP_VER="8.2" ;; # safe default
    esac
fi

# Pre-create minimal PHP-FPM config to survive dpkg conf-miss scenarios
ensure_php_fpm_baseline() {
    local base="/etc/php/${PHP_VER}/fpm"
    mkdir -p "${base}/pool.d" /run/php
    [[ -f "${base}/php-fpm.conf" ]] || cat >"${base}/php-fpm.conf" <<EOF
[global]
pid = /run/php/php${PHP_VER}-fpm.pid
error_log = /var/log/php${PHP_VER}-fpm.log
include=/etc/php/${PHP_VER}/fpm/pool.d/*.conf
EOF
    [[ -f "${base}/pool.d/www.conf" ]] || cat >"${base}/pool.d/www.conf" <<EOF
[www]
user = www-data
group = www-data
listen = /run/php/php${PHP_VER}-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF
}
ensure_php_fpm_baseline

# pre-create mysql dir/file to avoid mariadb-common alt path error
mkdir -p /etc/mysql
[[ -f /etc/mysql/mariadb.cnf ]] || echo "# placeholder created by install.sh" > /etc/mysql/mariadb.cnf

# install prerequisites
echo -e "${GREEN}[INFO] installing required packages...${NC}"
apt update -y
# avoid php meta (pulls mod_php); install without recommends
PKGS=(wget curl gnupg2 jq apt-transport-https
      php-cli php-fpm php-mysql php-xml php-bcmath php-mbstring php-ldap php-gd php-zip php-curl
      mariadb-server mariadb-client rsync socat ssl-cert fping snmpd apache2)
set +e
apt -o APT::Install-Recommends=false install -y "${PKGS[@]}"
APT_STATUS=$?
if (( APT_STATUS != 0 )); then
    echo -e "${YELLOW}[WARN] initial package install failed (code $APT_STATUS). Retrying with fix-broken...${NC}"
    apt --fix-broken install -y
    apt -o APT::Install-Recommends=false install -y "${PKGS[@]}"
    (( $? == 0 )) || { echo -e "${RED}[ERROR] package installation failed after retry.${NC}"; exit 1; }
fi
set -e

# add zabbix repo
echo -e "${GREEN}[INFO] adding Zabbix repository...${NC}"
wget -qO /tmp/zabbix-release.deb "$REPO_URL"
dpkg -i /tmp/zabbix-release.deb
apt update -y

# install zabbix server, frontend, agent (no recommends to avoid mod_php)
echo -e "${GREEN}[INFO] installing Zabbix packages...${NC}"
DEBIAN_FRONTEND=noninteractive apt -o APT::Install-Recommends=false install -y \
    zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

# Ensure Apache uses PHP-FPM (purge mod_php if present, enable proxy + fpm)
if dpkg -l | grep -q '^ii\s\+libapache2-mod-php'; then
    apt purge -y 'libapache2-mod-php*' || true
fi
if command -v a2dismod >/dev/null 2>&1; then
    a2dismod -f php* mpm_prefork || true
fi
# Some images miss helper symlinks before first start; ensure dirs exist
mkdir -p /etc/apache2/mods-available /etc/apache2/conf-available /etc/apache2/conf-enabled
if command -v a2enmod >/dev/null 2>&1; then
    a2enmod mpm_event proxy proxy_fcgi setenvif || true
fi
# Create php-fpm Apache conf if distro one is missing
PHP_FPM_CONF="/etc/apache2/conf-available/php${PHP_VER}-fpm.conf"
if [[ ! -f "$PHP_FPM_CONF" ]]; then
    cat >"$PHP_FPM_CONF" <<EOF
# minimal php-fpm wiring
<FilesMatch \.php$>
    SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost/"
</FilesMatch>
EOF
fi
if command -v a2enconf >/dev/null 2>&1; then
    a2enconf "php${PHP_VER}-fpm" || a2enconf "$(basename "$PHP_FPM_CONF" .conf)" || true
fi
systemctl enable --now "php${PHP_VER}-fpm" || true
systemctl enable --now apache2 || true
systemctl reload apache2 || true

# configure database
echo -e "${GREEN}[INFO] configuring MariaDB...${NC}"
# ensure mariadb is running (some images don't auto-start)
systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysql 2>/dev/null || true
# wait for socket up to 30s
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

# Import schema only if not present
echo -e "${GREEN}[INFO] importing initial Zabbix schema (if needed)...${NC}"
if ! mysql "${MYSQL_ROOT_ARGS[@]}" -Nse "SELECT 1 FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name='users' LIMIT 1;" | grep -q 1; then
    zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
else
    echo -e "${YELLOW}[SKIP] schema already exists in $DB_NAME.${NC}"
fi

# configure zabbix server
echo -e "${GREEN}[INFO] configuring Zabbix server...${NC}"
# ensure DBName/DBUser/DBPassword reflect provided values
sed -i "s|^#\? DBName=.*|DBName=$DB_NAME|" /etc/zabbix/zabbix_server.conf
sed -i "s|^#\? DBUser=.*|DBUser=$DB_USER|" /etc/zabbix/zabbix_server.conf
sed -i "s|^#\? DBPassword=.*|DBPassword=$DB_PASS|" /etc/zabbix/zabbix_server.conf
# ensure DBType is lowercase mysql for modern Zabbix
if grep -Eq '^[[:space:]]*#?[[:space:]]*DBType' /etc/zabbix/zabbix_server.conf; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*DBType=.*|DBType=mysql|" /etc/zabbix/zabbix_server.conf
else
    echo "DBType=mysql" >> /etc/zabbix/zabbix_server.conf
fi

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

# configure php timezone for both CLI and FPM
echo -e "${GREEN}[INFO] setting PHP timezone...${NC}"
for SAPI in fpm cli; do
    PHP_INI="/etc/php/${PHP_VER}/${SAPI}/php.ini"
    [[ -f "$PHP_INI" ]] && sed -i "s|^;*date.timezone =.*|date.timezone = UTC|" "$PHP_INI"
done

# Ensure required PHP MySQL extensions are enabled (mysqli, pdo_mysql)
echo -e "${GREEN}[INFO] ensuring PHP MySQL extensions (mysqli, pdo_mysql) are enabled...${NC}"
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
# Create a minimal php.ini for FPM/CLI if dpkg refused to restore it (ensures MySQL drivers are loaded)
ensure_php_ini_baseline() {
	for SAPI in fpm cli; do
		local INI="/etc/php/${PHP_VER}/${SAPI}/php.ini"
		mkdir -p "/etc/php/${PHP_VER}/${SAPI}"
		if [[ ! -f "$INI" ]]; then
			cat >"$INI" <<EOF
[PHP]
date.timezone = UTC
; ensure MySQL drivers are available for Zabbix frontend
extension=mysqli
extension=pdo_mysql
; common sane defaults
expose_php = Off
memory_limit = 256M
post_max_size = 16M
upload_max_filesize = 16M
max_execution_time = 300
EOF
		fi
	done
}
ensure_php_ini_baseline
systemctl restart "php${PHP_VER}-fpm" || true

# create frontend config
echo -e "${GREEN}[INFO] creating frontend configuration...${NC}"
FRONTEND_CONF="/etc/zabbix/web/zabbix.conf.php"
# Prefer MYSQL (expects mysqli extension). Fallback to MYSQLi if mysqli is unavailable.
FRONTEND_DB_TYPE="MYSQL"
php -m 2>/dev/null | grep -qi '^mysqli$' || FRONTEND_DB_TYPE="MYSQLi"
cat > "$FRONTEND_CONF" <<EOF
<?php
\$DB['TYPE']     = '${FRONTEND_DB_TYPE}';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = '$DB_NAME';
\$DB['USER']     = '$DB_USER';
\$DB['PASSWORD'] = '$DB_PASS';
?>
EOF

# start and enable Zabbix services
echo -e "${GREEN}[INFO] starting and enabling Zabbix services...${NC}"
systemctl daemon-reload
systemctl restart zabbix-server zabbix-agent
systemctl enable zabbix-server zabbix-agent

# Optionally set Frontend Admin password via API (best-effort)
if [[ -n "${ZABBIX_ADMIN_PASS:-}" ]]; then
    echo -e "${GREEN}[INFO] setting Zabbix Frontend Admin password...${NC}"
    TOKEN=""
    for i in {1..30}; do
        TOKEN="$(curl -s -X POST -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' \
            "http://127.0.0.1/zabbix/api_jsonrpc.php" | jq -r '.result // empty' || true)"
        [[ -n "$TOKEN" ]] && break
        sleep 2
    done
    if [[ -n "$TOKEN" ]]; then
        curl -s -X POST -H 'Content-Type: application/json' \
            -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.update\",\"params\":{\"userid\":\"1\",\"passwd\":\"$ZABBIX_ADMIN_PASS\"},\"auth\":\"$TOKEN\",\"id\":1}" \
            "http://127.0.0.1/zabbix/api_jsonrpc.php" >/dev/null || true
        echo -e "${GREEN}[OK] Admin password updated.${NC}"
    else
        echo -e "${YELLOW}[WARN] Could not set Admin password automatically. You can change it in the UI.${NC}"
    fi
fi

# cleanup temporary files and packages
echo -e "${GREEN}[INFO] cleaning up temporary files...${NC}"
rm -f /tmp/zabbix-release.deb
apt autoremove -y

echo -e "${GREEN}[OK] Zabbix installation complete!${NC}"
echo "Access frontend at: http://$ZABBIX_IP/zabbix"
echo "Username: Admin"
echo "Password: $ZABBIX_ADMIN_PASS"
