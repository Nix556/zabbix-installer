#!/bin/bash
# Full Zabbix uninstaller

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin
set -euo pipefail
IFS=$'\n\t'

LIB_DIR="lib"
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/utils.sh"
source "$LIB_DIR/db.sh"

wait_spinner() {
    local pid=$!
    local delay=0.2
    local spinstr='|/-\'
    printf "Working... "
    while kill -0 $pid 2>/dev/null; do
        for i in $(seq 0 3); do
            printf "\b${spinstr:$i:1}"
            sleep $delay
        done
    done
    wait $pid
    echo -e "\b[OK]"
}

echo -e "${YELLOW}[WARNING] This will completely remove Zabbix!${NC}"
confirm "Are you sure you want to uninstall Zabbix?" || { warn "Cancelled"; exit 0; }

while true; do
    read -rsp "Enter MariaDB root password: " ROOT_PASS; echo
    [[ -n "$ROOT_PASS" ]] && break
done
DB_NAME=$(ask "Enter Zabbix database to remove" "zabbix")

info "Stopping services..."
systemctl stop zabbix-server zabbix-agent apache2 & wait_spinner

info "Removing packages..."
apt purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent & wait_spinner

info "Removing configs..."
rm -rf /etc/zabbix /usr/share/zabbix /etc/apache2/conf-available/zabbix.conf /etc/apache2/conf-enabled/zabbix.conf config/zabbix_api.conf & wait_spinner

drop_zabbix_db "$DB_NAME" "zabbix" "$ROOT_PASS"

apt autoremove -y & wait_spinner

success "Zabbix uninstallation complete!"
