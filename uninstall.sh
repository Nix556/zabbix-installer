#!/bin/bash
# zabbix 7.4 uninstaller for Debian 12 / Ubuntu 22.04
# fully interactive, removes server, agent, frontend, database and data

set -euo pipefail
IFS=$'\n\t'

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root (sudo).${NC}"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# Detect PHP version for service management
if command -v php >/dev/null 2>&1; then
    PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")"
else
    PHP_VER="8.2"
fi

echo -e "${YELLOW}WARNING: This will REMOVE Zabbix server, agent, frontend, database and data.${NC}"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 0; }

read -rp "Zabbix DB name [zabbix]: " DB_NAME
DB_NAME=${DB_NAME:-zabbix}
read -rp "Zabbix DB user [zabbix]: " DB_USER
DB_USER=${DB_USER:-zabbix}
read -rsp "MariaDB root password (leave empty if socket auth): " ROOT_PASS; echo

# Ask whether to remove supporting stack
read -rp "Also purge ALL auxiliary packages (Apache, MariaDB, PHP, tools)? [y/N]: " PURGE_ALL
PURGE_ALL=${PURGE_ALL:-N}

# Drop database BEFORE stopping MariaDB
echo -e "${GREEN}[INFO] Dropping database and user (if exist)...${NC}"
if command -v mysql >/dev/null 2>&1; then
    # Ensure MariaDB is running for database operations
    systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
    sleep 2
    
    MYSQL_ROOT_ARGS=(-uroot)
    [[ -n "${ROOT_PASS}" ]] && MYSQL_ROOT_ARGS+=(-p"${ROOT_PASS}")
    
    if mysql "${MYSQL_ROOT_ARGS[@]}" -e "SELECT 1" >/dev/null 2>&1; then
        mysql "${MYSQL_ROOT_ARGS[@]}" <<EOF || true
DROP DATABASE IF EXISTS \`$DB_NAME\`;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
        echo -e "${GREEN}[OK] Database and user dropped.${NC}"
    else
        echo -e "${YELLOW}[WARN] Could not connect to MariaDB; DB/User removal skipped.${NC}"
    fi
else
    echo -e "${YELLOW}[WARN] mysql client not found; skipping database/user removal.${NC}"
fi

echo -e "${GREEN}[INFO] Stopping services...${NC}"
stop_if() { systemctl stop "$1" 2>/dev/null || true; systemctl disable "$1" 2>/dev/null || true; }
for svc in zabbix-server zabbix-agent zabbix-agent2 apache2 "php${PHP_VER}-fpm" php-fpm mariadb mysql snmpd; do stop_if "$svc"; done

# Fix any broken package states before we start (prevents dpkg failures during uninstall)
echo -e "${GREEN}[INFO] Fixing any broken package states...${NC}"
# Pre-create directories that broken packages might need for configuration
mkdir -p /var/lib/snmp /etc/snmp 2>/dev/null || true
chown -R Debian-snmp:Debian-snmp /var/lib/snmp 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true
apt --fix-broken install -y 2>/dev/null || true

# Remove Zabbix files first so dpkg won't complain about non-empty directories during purge
echo -e "${GREEN}[INFO] Removing Zabbix residual files (before purge)...${NC}"
rm -rf /var/log/zabbix \
       /var/lib/zabbix \
       /usr/share/zabbix \
       /etc/zabbix/web/zabbix.conf.php \
       /usr/share/zabbix/sql-scripts
# remove agent d dir to avoid dpkg warnings
rm -rf /etc/zabbix/zabbix_agentd.d || true
# remove any zabbix apache conf files early
rm -f /etc/apache2/conf-available/zabbix.conf /etc/apache2/conf-enabled/zabbix.conf || true
rm -f /etc/apache2/conf-available/zabbix-override.conf /etc/apache2/conf-enabled/zabbix-override.conf || true

echo -e "${GREEN}[INFO] Purging Zabbix packages...${NC}"
ZBX_PKGS=(zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent zabbix-agent2 zabbix-release)
INSTALLED_ZBX=($(dpkg -l | awk '/^ii|^iF|^iU/ {print $2}' | grep -E '^zabbix-' || true))
[[ ${#INSTALLED_ZBX[@]} -gt 0 ]] && apt purge -y "${INSTALLED_ZBX[@]}" 2>/dev/null || echo -e "${YELLOW}[INFO] No Zabbix packages installed to purge.${NC}"

# Remove Zabbix repository
echo -e "${GREEN}[INFO] Removing Zabbix repository...${NC}"
rm -f /etc/apt/sources.list.d/zabbix*.list || true
rm -f /etc/apt/trusted.gpg.d/zabbix*.gpg || true
rm -f /usr/share/keyrings/zabbix*.gpg || true
apt update -y 2>/dev/null || true

if [[ "$PURGE_ALL" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}[INFO] Purging auxiliary stack (Apache, MariaDB, PHP, tools)...${NC}"
    
    # Remove residual files BEFORE purge to avoid dpkg warnings about non-empty directories
    echo -e "${GREEN}[INFO] Removing auxiliary residual files (before purge)...${NC}"
    rm -rf /var/lib/apache2 /var/cache/apache2 /var/log/apache2 /etc/apache2 /var/www/html \
           /etc/php /var/lib/php /var/log/php* /run/php \
           /var/lib/mysql /var/log/mysql* /etc/mysql /run/mysqld /var/cache/mysql \
           /etc/snmp /var/lib/snmp /var/log/snmpd.log || true
    
    # Complete list matching install.sh packages
    AUX_PKGS=(
        # Apache packages
        apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php "libapache2-mod-php${PHP_VER}"
        # MariaDB/MySQL packages
        mariadb-server mariadb-client mariadb-common mariadb-server-core mariadb-client-core mysql-common galera-4
        # PHP packages (version-specific and generic)
        php php-cli php-fpm php-mysql php-xml php-bcmath php-mbstring php-ldap php-gd php-zip php-curl php-common
        "php${PHP_VER}" "php${PHP_VER}-cli" "php${PHP_VER}-fpm" "php${PHP_VER}-mysql" "php${PHP_VER}-xml"
        "php${PHP_VER}-bcmath" "php${PHP_VER}-mbstring" "php${PHP_VER}-ldap" "php${PHP_VER}-gd" "php${PHP_VER}-zip"
        "php${PHP_VER}-curl" "php${PHP_VER}-common" "php${PHP_VER}-opcache" "php${PHP_VER}-readline"
        # Tools installed by install.sh
        wget curl gnupg2 jq apt-transport-https rsync socat ssl-cert fping snmpd snmp-mibs-downloader
    )
    
    INSTALLED_AUX=($(dpkg -l | awk '/^ii|^iF|^iU/ {print $2}' | grep -x -F -f <(printf "%s\n" "${AUX_PKGS[@]}") || true))
    if [[ ${#INSTALLED_AUX[@]} -gt 0 ]]; then
        # Force remove to handle broken states
        apt purge -y "${INSTALLED_AUX[@]}" 2>/dev/null || dpkg --purge --force-remove-reinstreq "${INSTALLED_AUX[@]}" 2>/dev/null || true
    else
        echo -e "${YELLOW}[INFO] No auxiliary packages installed to purge.${NC}"
    fi
    
    # Remove any remaining auxiliary residual files AFTER purge
    echo -e "${GREEN}[INFO] Final cleanup of auxiliary residual files...${NC}"
    rm -rf /var/lib/apache2 /var/cache/apache2 /var/log/apache2 /etc/apache2 /var/www/html \
           /etc/php /var/lib/php /var/log/php* /run/php \
           /var/lib/mysql /var/log/mysql* /etc/mysql /run/mysqld /var/cache/mysql \
           /etc/snmp /var/lib/snmp /var/log/snmpd.log || true
fi

# Always remove the entire /etc/zabbix directory at the end
echo -e "${GREEN}[INFO] Removing remaining Zabbix configuration...${NC}"
rm -rf /etc/zabbix || true

echo -e "${GREEN}[INFO] Cleaning apt...${NC}"
dpkg --configure -a 2>/dev/null || true
apt --fix-broken install -y 2>/dev/null || true
apt autoremove -y 2>/dev/null || true
apt autoclean -y

echo -e "${GREEN}[INFO] Done.${NC}"
echo "Removed packages: ${INSTALLED_ZBX[*]:-none}"
[[ "$PURGE_ALL" =~ ^[Yy]$ ]] && echo "Also purged auxiliary packages: ${INSTALLED_AUX[*]:-none}"
echo "Database/user dropped: $DB_NAME / $DB_USER"
echo -e "${YELLOW}If you installed extra dependencies manually, review and remove them as needed.${NC}"