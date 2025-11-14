#!/bin/bash
# Zabbix 7.4 uninstaller using lib scripts

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/db.sh"
source "$SCRIPT_DIR/lib/system.sh"

info "This will completely remove Zabbix and its database!"
if ! confirm "Are you sure you want to continue?"; then
    success "Uninstallation canceled."
    exit 0
fi

# Stop services
stop_service zabbix-server || true
stop_service zabbix-agent || true
stop_service apache2 || true

# Ask for MariaDB root password
while true; do
    read -rsp "Enter MariaDB root password: " ROOT_PASS
    echo
    [[ -n "$ROOT_PASS" ]] && break
done

# Ask for database name and user
DB_NAME=$(ask "Enter Zabbix database name to delete" "zabbix")
DB_USER=$(ask "Enter Zabbix database user to delete" "zabbix")

# Confirm database deletion
if confirm "This will DROP the database '$DB_NAME' and user '$DB_USER'. Continue?"; then
    drop_zabbix_db "$DB_NAME" "$DB_USER" "$ROOT_PASS"
else
    warn "Skipping database deletion."
fi

# Remove packages
info "Removing Zabbix packages..."
DEBIAN_FRONTEND=noninteractive apt purge -y \
    zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent \
    zabbix-agent-mysql zabbix-sql-scripts

# Remove configuration
info "Removing configuration files..."
rm -rf /etc/zabbix /usr/share/zabbix /var/log/zabbix /var/lib/zabbix

# Remove Zabbix repo
if dpkg -l | grep -q zabbix-release; then
    info "Removing Zabbix repository package..."
    dpkg -r zabbix-release || true
fi
rm -f /tmp/zabbix-release.deb

# Remove Apache Zabbix config
if [ -f /etc/apache2/conf-available/zabbix.conf ]; then
    a2disconf zabbix || true
    rm -f /etc/apache2/conf-available/zabbix.conf
    systemctl reload apache2 || true
fi

# Cleanup
info "Cleaning up unused packages..."
apt autoremove -y
apt update -y

success "Zabbix uninstallation complete!"
