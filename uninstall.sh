#!/bin/bash

set -e
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$BASE_DIR/lib"
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/utils.sh"
source "$LIB_DIR/system.sh"
source "$LIB_DIR/db.sh"

run_cmd() {
    if [[ $EUID -eq 0 ]]; then
        bash -c "$1"
    else
        sudo bash -c "$1"
    fi
}

echo ""
warn "This will completely remove Zabbix server, agent, database, and web interface."
read -rp "Are you sure you want to continue? (y/N): " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && { info "Aborted."; exit 0; }

ZBX_CONF="/etc/zabbix/zabbix_server.conf"

if [[ -f "$ZBX_CONF" ]]; then
    ZABBIX_DB_NAME=$(grep -E '^DBName=' "$ZBX_CONF" | cut -d'=' -f2)
    ZABBIX_DB_USER=$(grep -E '^DBUser=' "$ZBX_CONF" | cut -d'=' -f2)
    [[ -z "$ZABBIX_DB_NAME" ]] && ZABBIX_DB_NAME="zabbix"
    [[ -z "$ZABBIX_DB_USER" ]] && ZABBIX_DB_USER="zabbix"
    info "Detected database: $ZABBIX_DB_NAME"
    info "Detected user: $ZABBIX_DB_USER"
else
    warn "Zabbix config not found, using defaults."
    ZABBIX_DB_NAME="zabbix"
    ZABBIX_DB_USER="zabbix"
fi

read -rp "Enter MariaDB root password (for DB removal): " DB_ROOT_PASS

info "Stopping Zabbix and Apache services..."
run_cmd "systemctl stop zabbix-server zabbix-agent apache2 || true"
success "Services stopped"

info "Dropping Zabbix database and user..."
(
    sleep 1
    run_cmd "mysql -u root -p\"$DB_ROOT_PASS\" -e 'DROP DATABASE IF EXISTS \`$ZABBIX_DB_NAME\`; DROP USER IF EXISTS \`$ZABBIX_DB_USER\`@\"localhost\";'"
    sleep 1
) &

show_spinner $! "Dropping database..." "Database and user dropped"

info "Removing Zabbix, Apache, and MariaDB packages..."
run_cmd "apt remove -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent apache2 mariadb-server >/dev/null"
run_cmd "apt autoremove -y >/dev/null"
success "Packages removed"

info "Cleaning up configuration files and cache..."
run_cmd "rm -rf /etc/zabbix /var/log/zabbix /var/lib/mysql /etc/apache2/conf-enabled/zabbix.conf"
run_cmd "rm -rf $BASE_DIR/config/zabbix_api.conf 2>/dev/null || true"
success "Configuration cleaned up"

success "Zabbix uninstallation complete!"
echo "All services, database, and configuration files have been removed."
