#!/bin/bash
set -e

export PATH=$PATH:/sbin:/usr/sbin:/usr/local/sbin

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$BASE_DIR/lib"
CONFIG_DIR="$BASE_DIR/config"
mkdir -p "$CONFIG_DIR"

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

info "Detecting OS..."
detect_os
success "OS detected: $OS_NAME $OS_VERSION"

ZABBIX_IP=$(ask "Enter Zabbix Server IP:" "127.0.0.1")
while ! validate_ip "$ZABBIX_IP"; do
    warn "Invalid IP address"
    ZABBIX_IP=$(ask "Enter a valid Zabbix Server IP:" "$ZABBIX_IP")
done

ZABBIX_DB_NAME=$(ask "Enter Zabbix DB name:" "zabbix")
ZABBIX_DB_USER=$(ask "Enter Zabbix DB user:" "zabbix")

while true; do
    read -rp "Enter Zabbix DB password: []: " ZABBIX_DB_PASS
    [[ -n "$ZABBIX_DB_PASS" ]] && break || warn "Password cannot be empty"
done

read -rp "Enter MariaDB root password: []: " DB_ROOT_PASS
read -rp "Enter Zabbix Admin password (frontend): [zabbix]: " ZABBIX_ADMIN_PASS
ZABBIX_ADMIN_PASS=${ZABBIX_ADMIN_PASS:-zabbix}

echo ""
info "Configuration summary:"
echo "DB: $ZABBIX_DB_NAME / $ZABBIX_DB_USER"
echo "Zabbix IP: $ZABBIX_IP"
echo "Zabbix Admin password: $ZABBIX_ADMIN_PASS"
echo ""

info "Installing required packages..."
run_cmd "apt update -y"
run_cmd "apt install -y wget curl gnupg2 lsb-release jq apt-transport-https mariadb-server apache2 php php-mysql php-xml php-bcmath php-mbstring php-ldap php-json php-gd php-zip"
success "Prerequisites installed"

info "Adding Zabbix 7.4 repository..."
DEB_CODENAME=$(lsb_release -cs | tr '[:upper:]' '[:lower:]')
if [[ "$OS_NAME" == "Debian" ]]; then
    # Use bullseye_all.deb for Debian 12
    ZBX_REPO_URL="https://repo.zabbix.com/zabbix/7.4/debian/pool/main/z/zabbix-release/zabbix-release_7.4-1+bullseye_all.deb"
else
    ZBX_REPO_URL="https://repo.zabbix.com/zabbix/7.4/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.4-1+${DEB_CODENAME}_all.deb"
fi

run_cmd "wget -O /tmp/zabbix-release.deb $ZBX_REPO_URL"
run_cmd "dpkg -i /tmp/zabbix-release.deb"
run_cmd "apt update -y"
success "Zabbix repository added"

info "Installing Zabbix server, frontend, and agent..."
run_cmd "apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent"
success "Zabbix installed"

info "Creating Zabbix database..."
create_zabbix_db "$ZABBIX_DB_NAME" "$ZABBIX_DB_USER" "$ZABBIX_DB_PASS" "$DB_ROOT_PASS"
success "Database created"

info "Importing initial schema..."
SCHEMA_FILE=$(find /usr/share -type f -name "server.sql.gz" 2>/dev/null | head -n1)
if [[ -f "$SCHEMA_FILE" ]]; then
    run_cmd "zcat $SCHEMA_FILE | mysql -u\"$ZABBIX_DB_USER\" -p\"$ZABBIX_DB_PASS\" \"$ZABBIX_DB_NAME\""
    success "Schema imported"
else
    error "Zabbix SQL schema not found! Verify zabbix-sql-scripts package."
    exit 1
fi

info "Configuring Zabbix server..."
ZABBIX_CONF="/etc/zabbix/zabbix_server.conf"
run_cmd "sed -i \"s/^# DBHost=.*/DBHost=localhost/\" $ZABBIX_CONF"
run_cmd "sed -i \"s/^# DBName=.*/DBName=$ZABBIX_DB_NAME/\" $ZABBIX_CONF"
run_cmd "sed -i \"s/^# DBUser=.*/DBUser=$ZABBIX_DB_USER/\" $ZABBIX_CONF"
run_cmd "sed -i \"s/^# DBPassword=.*/DBPassword=$ZABBIX_DB_PASS/\" $ZABBIX_CONF"
success "Zabbix server configured"

PHP_INI="/etc/php/*/apache2/php.ini"
run_cmd "sed -i 's@^;date.timezone =.*@date.timezone = Europe/Copenhagen@' $PHP_INI"
success "PHP configured"

info "Starting Zabbix and Apache..."
run_cmd "systemctl enable zabbix-server zabbix-agent apache2"
run_cmd "systemctl restart zabbix-server zabbix-agent apache2"
success "Services started"

info "Generating API configuration..."
cat > "$CONFIG_DIR/zabbix_api.conf" <<EOF
# Zabbix API configuration
ZABBIX_URL="http://$ZABBIX_IP/zabbix"
ZABBIX_USER="Admin"
ZABBIX_PASS="$ZABBIX_ADMIN_PASS"
EOF
success "API configuration generated at config/zabbix_api.conf"

success "Zabbix 7.4 installation complete!"
echo "Frontend URL: http://$ZABBIX_IP/zabbix"
echo "Admin user: Admin"
echo "Admin password: $ZABBIX_ADMIN_PASS"
