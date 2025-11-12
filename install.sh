#!/bin/bash
set -e
source lib/colors.sh
source lib/utils.sh
source lib/system.sh
source lib/db.sh

spinner() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
}

run_with_spinner() { "$@" & spinner; }

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        for i in $(echo $ip | tr '.' ' '); do
            if ((i < 0 || i > 255)); then return 1; fi
        done
        return 0
    else
        return 1
    fi
}

info "Detecting OS..."
detect_os
success "OS detected: $OS $VER"

while true; do
    ZABBIX_IP=$(ask "Enter Zabbix Server IP: " "127.0.0.1")
    if validate_ip "$ZABBIX_IP"; then break; else warning "Invalid IP"; fi
done

DB_NAME=$(ask "Enter Zabbix DB name: " "zabbix")
DB_USER=$(ask "Enter Zabbix DB user: " "zabbix")
while true; do
    DB_PASS=$(ask "Enter Zabbix DB password: " "")
    [[ -n "$DB_PASS" ]] && break || warning "Password cannot be empty"
done
while true; do
    ROOT_PASS=$(ask "Enter MariaDB root password: " "")
    [[ -n "$ROOT_PASS" ]] && break || warning "Root password cannot be empty"
done
while true; do
    ZABBIX_ADMIN_PASS=$(ask "Enter Zabbix Admin password (frontend): " "zabbix")
    [[ -n "$ZABBIX_ADMIN_PASS" ]] && break || warning "Password cannot be empty"
done

info "Configuration summary:"
echo "DB: $DB_NAME / $DB_USER"
echo "Zabbix IP: $ZABBIX_IP"
echo "Zabbix Admin password: $ZABBIX_ADMIN_PASS"

info "Installing required packages..."
run_with_spinner sudo $PM install -y wget curl gnupg2 software-properties-common lsb-release \
    apache2 mariadb-server mariadb-client php8.2 php8.2-mysql php8.2-gd \
    php8.2-bcmath php8.2-mbstring php8.2-xml php8.2-ldap php8.2-curl jq
success "Prerequisites installed ✅"

info "Adding Zabbix 7.4 repository..."
run_with_spinner bash -c "wget -q https://repo.zabbix.com/zabbix/7.4/${OS}/$(lsb_release -cs)/amd64/zabbix-release_7.4-1+${OS}$(lsb_release -rs)_all.deb && \
    sudo dpkg -i zabbix-release_7.4-1+${OS}$(lsb_release -rs)_all.deb >/dev/null && sudo $PM update -y >/dev/null"
success "Zabbix repository added ✅"

info "Installing Zabbix server, frontend, and agent..."
run_with_spinner sudo $PM install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
    zabbix-sql-scripts zabbix-agent >/dev/null
success "Zabbix installed ✅"

info "Creating Zabbix database..."
run_with_spinner create_zabbix_db "$DB_NAME" "$DB_USER" "$DB_PASS" "$ROOT_PASS"
success "Database created ✅"

info "Importing initial schema..."
run_with_spinner bash -c "zcat /usr/share/doc/zabbix-sql-scripts/mysql/create.sql.gz | mysql -u'$DB_USER' -p'$DB_PASS' '$DB_NAME'"
success "Schema imported ✅"

info "Configuring Zabbix server..."
sudo sed -i "s/^DBName=.*/DBName=$DB_NAME/" /etc/zabbix/zabbix_server.conf
sudo sed -i "s/^DBUser=.*/DBUser=$DB_USER/" /etc/zabbix/zabbix_server.conf
sudo sed -i "s/^# DBPassword=.*/DBPassword=$DB_PASS/" /etc/zabbix/zabbix_server.conf
success "Zabbix server configuration updated ✅"

info "Starting Zabbix services..."
run_with_spinner sudo systemctl enable --now zabbix-server zabbix-agent apache2
success "Services started ✅"

info "Setting Zabbix Admin password..."
run_with_spinner sudo mysql -uroot -p"$ROOT_PASS" "$DB_NAME" -e "UPDATE users SET passwd=MD5('$ZABBIX_ADMIN_PASS') WHERE alias='Admin';"
success "Admin password set ✅"

info "Generating API configuration..."
mkdir -p config
cat > config/zabbix_api.conf <<EOF
ZABBIX_URL="http://$ZABBIX_IP/zabbix"
ZABBIX_USER="Admin"
ZABBIX_PASS="$ZABBIX_ADMIN_PASS"
EOF
success "API config generated at config/zabbix_api.conf ✅"

success "Zabbix 7.4 installation complete!"
echo "Frontend URL: http://$ZABBIX_IP/zabbix"
echo "Admin user: Admin"
echo "Admin password: $ZABBIX_ADMIN_PASS"
