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
read -rp "Also purge MariaDB + PHP packages? [y/N]: " PURGE_STACK
PURGE_STACK=${PURGE_STACK:-N}

echo -e "${GREEN}[INFO] Stopping services...${NC}"
stop_if() { systemctl stop "$1" 2>/dev/null || true; systemctl disable "$1" 2>/dev/null || true; }
for svc in zabbix-server zabbix-agent apache2 php*-fpm mariadb mysql; do stop_if "$svc"; done

echo -e "${GREEN}[INFO] Dropping database and user (if exist)...${NC}"
MYSQL_ROOT_ARGS=(-uroot)
[[ -n "${ROOT_PASS}" ]] && MYSQL_ROOT_ARGS+=(-p"${ROOT_PASS}")
# Test connectivity (ignore failure if socket auth without password)
mysql "${MYSQL_ROOT_ARGS[@]}" -e "SELECT 1" >/dev/null 2>&1 || echo -e "${YELLOW}[WARN] Could not verify MariaDB root access; DB/User removal may fail.${NC}"

mysql "${MYSQL_ROOT_ARGS[@]}" <<EOF || true
DROP DATABASE IF EXISTS \`$DB_NAME\`;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

echo -e "${GREEN}[INFO] Purging Zabbix packages...${NC}"
ZBX_PKGS=(zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent)
apt purge -y "${ZBX_PKGS[@]}" 2>/dev/null || true

if [[ "$PURGE_STACK" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}[INFO] Purging MariaDB + PHP stack...${NC}"
    apt purge -y mariadb-server mariadb-client php php-fpm php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip php-curl 2>/dev/null || true
fi

echo -e "${GREEN}[INFO] Removing residual files...${NC}"
rm -rf /etc/zabbix \
       /var/log/zabbix \
       /var/lib/zabbix \
       /usr/share/zabbix \
       /etc/apache2/conf-available/zabbix.conf \
       /etc/apache2/conf-enabled/zabbix.conf \
       /etc/zabbix/web/zabbix.conf.php

echo -e "${GREEN}[INFO] Cleaning apt...${NC}"
apt autoremove -y
apt autoclean -y

echo -e "${GREEN}[INFO] Done.${NC}"
echo "Removed packages: ${ZBX_PKGS[*]}"
[[ "$PURGE_STACK" =~ ^[Yy]$ ]] && echo "Also purged MariaDB + PHP."
echo "Database/user dropped: $DB_NAME / $DB_USER"
echo -e "${YELLOW}If you installed extra dependencies manually, review and remove them as needed.${NC}"
