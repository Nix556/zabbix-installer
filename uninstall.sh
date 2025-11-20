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

echo -e "${GREEN}[INFO] Stopping services...${NC}"
stop_if() { systemctl stop "$1" 2>/dev/null || true; systemctl disable "$1" 2>/dev/null || true; }
for svc in zabbix-server zabbix-agent apache2 php*-fpm mariadb mysql; do stop_if "$svc"; done

echo -e "${GREEN}[INFO] Dropping database and user (if exist)...${NC}"
if command -v mysql >/dev/null 2>&1; then
    MYSQL_ROOT_ARGS=(-uroot)
    [[ -n "${ROOT_PASS}" ]] && MYSQL_ROOT_ARGS+=(-p"${ROOT_PASS}")
    mysql "${MYSQL_ROOT_ARGS[@]}" -e "SELECT 1" >/dev/null 2>&1 || echo -e "${YELLOW}[WARN] Could not verify MariaDB root access; DB/User removal may fail.${NC}"
    mysql "${MYSQL_ROOT_ARGS[@]}" <<EOF || true
DROP DATABASE IF EXISTS \`$DB_NAME\`;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
else
    echo -e "${YELLOW}[WARN] mysql client not found; skipping database/user removal.${NC}"
fi

# Remove Zabbix files first so dpkg won't complain about non-empty directories during purge
echo -e "${GREEN}[INFO] Removing Zabbix residual files (before purge)...${NC}"
rm -rf /var/log/zabbix \
       /var/lib/zabbix \
       /usr/share/zabbix \
       /etc/zabbix/web/zabbix.conf.php
# remove agent d dir to avoid dpkg warnings
rm -rf /etc/zabbix/zabbix_agentd.d || true
# remove any zabbix apache conf files early
rm -f /etc/apache2/conf-available/zabbix.conf /etc/apache2/conf-enabled/zabbix.conf || true

echo -e "${GREEN}[INFO] Purging Zabbix packages...${NC}"
ZBX_PKGS=(zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent)
INSTALLED_ZBX=($(dpkg -l | awk '/^ii/ {print $2}' | grep -x -F -f <(printf "%s\n" "${ZBX_PKGS[@]}") || true))
[[ ${#INSTALLED_ZBX[@]} -gt 0 ]] && apt purge -y "${INSTALLED_ZBX[@]}" 2>/dev/null || echo -e "${YELLOW}[INFO] No Zabbix packages installed to purge.${NC}"

if [[ "$PURGE_ALL" =~ ^[Yy]$ ]]; then
    # Remove auxiliary residual files before purge to avoid dpkg warnings
    echo -e "${GREEN}[INFO] Removing auxiliary residual files (before purge)...${NC}"
    rm -rf /etc/apache2 /var/log/apache2 \
           /etc/php /var/lib/php /var/log/php* \
           /var/lib/mysql /var/log/mysql* /etc/mysql || true

    echo -e "${GREEN}[INFO] Purging auxiliary stack (Apache, MariaDB, PHP, tools)...${NC}"
    AUX_PKGS=(apache2 mariadb-server mariadb-client
              php php-fpm php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip php-curl
              libapache2-mod-php libapache2-mod-php8.2
              wget curl gnupg2 jq apt-transport-https rsync socat ssl-cert fping snmpd)
    INSTALLED_AUX=($(dpkg -l | awk '/^ii/ {print $2}' | grep -x -F -f <(printf "%s\n" "${AUX_PKGS[@]}") || true))
    [[ ${#INSTALLED_AUX[@]} -gt 0 ]] && apt purge -y "${INSTALLED_AUX[@]}" 2>/dev/null || echo -e "${YELLOW}[INFO] No auxiliary packages installed to purge.${NC}"
fi

echo -e "${GREEN}[INFO] Cleaning apt...${NC}"
apt autoremove -y
apt autoclean -y

echo -e "${GREEN}[INFO] Done.${NC}"
echo "Removed packages: ${INSTALLED_ZBX[*]:-none}"
[[ "$PURGE_ALL" =~ ^[Yy]$ ]] && echo "Also purged auxiliary packages: ${INSTALLED_AUX[*]:-none}"
echo "Database/user dropped: $DB_NAME / $DB_USER"
echo -e "${YELLOW}If you installed extra dependencies manually, review and remove them as needed.${NC}"
