#!/bin/bash
# zabbix 7.4 uninstaller - debian 11/12, ubuntu 22.04/24.04

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin
set -euo pipefail
IFS=$'\n\t'

# logging
LOG_FILE="/var/log/zabbix-installer.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Zabbix Uninstaller started: $(date) ===" >> "$LOG_FILE"

# colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
BOLD="\033[1m"
DIM="\033[2m"
NC="\033[0m"

# spinner with time tracking
SPIN_CHARS='/-\|'
spin_pid=""
spin_start_time=0

spinner_start() {
    local msg="$1"
    local estimate="${2:-}"
    spin_start_time=$(date +%s)
    (
        i=0
        while true; do
            elapsed=$(($(date +%s) - spin_start_time))
            elapsed_str="${elapsed}s"
            if [[ -n "$estimate" && "$estimate" -gt 0 ]]; then
                time_str="${elapsed_str} / ~${estimate}s"
            else
                time_str="${elapsed_str}"
            fi
            printf "\r\033[K  ${CYAN}${SPIN_CHARS:i++%4:1}${NC} %s ${DIM}[%s]${NC}" "$msg" "$time_str"
            sleep 0.1
        done
    ) &
    spin_pid=$!
    disown
}

spinner_stop() {
    local status="$1"
    local msg="$2"
    local elapsed=$(($(date +%s) - spin_start_time))
    [[ -n "${spin_pid:-}" ]] && kill "$spin_pid" 2>/dev/null || true
    spin_pid=""
    printf "\r\033[K"
    if [[ "$status" == "ok" ]]; then
        echo -e "  ${GREEN}+${NC} $msg ${DIM}(${elapsed}s)${NC}"
    elif [[ "$status" == "skip" ]]; then
        echo -e "  ${YELLOW}-${NC} $msg ${DIM}(${elapsed}s)${NC}"
    else
        echo -e "  ${RED}x${NC} $msg ${DIM}(${elapsed}s)${NC}"
    fi
}

header() {
    echo
    echo -e "${BOLD}${BLUE}:: $1${NC}"
}

success() {
    echo -e "  ${GREEN}+${NC} $1"
}

info() {
    echo -e "  ${DIM}$1${NC}"
}

warn() {
    echo -e "  ${YELLOW}!${NC} $1"
}

error() {
    echo -e "  ${RED}x${NC} $1"
}

divider() {
    echo -e "${DIM}  ────────────────────────────────────────${NC}"
}

run() {
    local msg="$1"
    local estimate="${2:-5}"
    shift 2 2>/dev/null || shift
    spinner_start "$msg" "$estimate"
    if "$@" >/dev/null 2>&1; then
        spinner_stop "ok" "$msg"
        return 0
    else
        spinner_stop "skip" "$msg"
        return 0
    fi
}

cleanup() {
    local exit_code=$?
    [[ -n "${spin_pid:-}" ]] && kill "$spin_pid" 2>/dev/null || true
    if [[ $exit_code -ne 0 ]]; then
        echo "=== Zabbix Uninstaller FAILED (exit code: $exit_code): $(date) ===" >> "$LOG_FILE"
    fi
}
trap cleanup EXIT

# banner
clear
echo
echo -e "${BOLD}${RED}  Zabbix 7.4 Uninstaller${NC}"
echo -e "${DIM}  Debian 11/12 | Ubuntu 22.04/24.04${NC}"
echo

# root check
[[ $EUID -ne 0 ]] && { error "Please run as root (sudo)"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# get php version
if command -v php >/dev/null 2>&1; then
    PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")"
else
    PHP_VER="8.2"
fi

# confirmation
header "Warning"
echo
echo -e "  ${YELLOW}This will permanently remove:${NC}"
echo -e "  ${DIM}- Zabbix server, agent, and frontend${NC}"
echo -e "  ${DIM}- Zabbix database and user${NC}"
echo -e "  ${DIM}- All configuration files${NC}"
echo
echo -ne "  ${RED}?${NC} Type ${BOLD}YES${NC} to continue: "
read -r CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo; warn "Aborted."; exit 0; }

# user input
header "Configuration"
echo

echo -ne "  ${CYAN}?${NC} Database name ${DIM}[zabbix]${NC}: "
read -r DB_NAME
DB_NAME=${DB_NAME:-zabbix}

echo -ne "  ${CYAN}?${NC} Database user ${DIM}[zabbix]${NC}: "
read -r DB_USER
DB_USER=${DB_USER:-zabbix}

# verify database connection before proceeding
SKIP_DATABASE=false
SKIP_REASON=""
ROOT_PASS=""

# find mysql client (could be mysql or mariadb)
MYSQL_CMD=""

# try to find existing client
for cmd in mariadb mysql; do
    if command -v "$cmd" >/dev/null 2>&1; then
        MYSQL_CMD="$cmd"
        break
    fi
done

# check common paths
if [[ -z "$MYSQL_CMD" ]]; then
    for path in /usr/bin/mariadb /usr/bin/mysql /usr/local/bin/mysql /usr/local/bin/mariadb; do
        if [[ -x "$path" ]]; then
            MYSQL_CMD="$path"
            break
        fi
    done
fi

# if still not found, offer to install it
if [[ -z "$MYSQL_CMD" ]]; then
    warn "MySQL/MariaDB client not installed"
    echo -ne "  ${CYAN}?${NC} Install mariadb-client to manage database? ${DIM}[Y/n]${NC}: "
    read -r install_client
    if [[ ! "$install_client" =~ ^[Nn]$ ]]; then
        spinner_start "Installing mariadb-client" 30
        if apt update -y >/dev/null 2>&1 && apt install -y mariadb-client >/dev/null 2>&1; then
            spinner_stop "ok" "Installed mariadb-client"
            # find the newly installed client
            for cmd in mariadb mysql; do
                if command -v "$cmd" >/dev/null 2>&1; then
                    MYSQL_CMD="$cmd"
                    break
                fi
            done
        else
            spinner_stop "fail" "Failed to install mariadb-client"
        fi
    fi
fi

if [[ -z "$MYSQL_CMD" ]]; then
    warn "Cannot manage database without client"
    SKIP_DATABASE=true
    SKIP_REASON="database client not available"
else
    systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
    sleep 2
    
    # check if socket auth works first
    if "$MYSQL_CMD" -uroot -e "SELECT 1" >/dev/null 2>&1; then
        MYSQL_ROOT_ARGS=(-uroot)
        success "Database connection OK (socket auth)"
    else
        # socket auth failed, need password
        warn "Socket auth not available, password required"
        echo -ne "  ${CYAN}?${NC} MariaDB root password: "
        read -rs ROOT_PASS
        echo
        
        if [[ -z "$ROOT_PASS" ]]; then
            error "Password required but not provided"
            echo -ne "  ${CYAN}?${NC} Continue without database operations? ${DIM}[y/N]${NC}: "
            read -r skip_db
            if [[ ! "$skip_db" =~ ^[Yy]$ ]]; then
                error "Aborted"
                exit 1
            fi
            SKIP_DATABASE=true
            SKIP_REASON="no password provided"
        else
            MYSQL_ROOT_ARGS=(-uroot -p"${ROOT_PASS}")
            if "$MYSQL_CMD" "${MYSQL_ROOT_ARGS[@]}" -e "SELECT 1" >/dev/null 2>&1; then
                success "Database connection OK (password auth)"
            else
                error "Wrong password"
                echo -ne "  ${CYAN}?${NC} Continue without database operations? ${DIM}[y/N]${NC}: "
                read -r skip_db
                if [[ ! "$skip_db" =~ ^[Yy]$ ]]; then
                    error "Aborted"
                    exit 1
                fi
                SKIP_DATABASE=true
                SKIP_REASON="authentication failed"
            fi
        fi
    fi
fi

echo -ne "  ${CYAN}?${NC} Also purge Apache, MariaDB, PHP? ${DIM}[y/N]${NC}: "
read -r PURGE_ALL
PURGE_ALL=${PURGE_ALL:-N}

echo -ne "  ${CYAN}?${NC} Backup database and config first? ${DIM}[Y/n]${NC}: "
read -r DO_BACKUP
DO_BACKUP=${DO_BACKUP:-Y}

# backup
if [[ "$DO_BACKUP" =~ ^[Yy]$ ]]; then
    header "Creating Backup"
    
    BACKUP_DIR="/root/zabbix-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # backup config
    if [[ -d /etc/zabbix ]]; then
        spinner_start "Backing up configuration" 3
        cp -a /etc/zabbix "$BACKUP_DIR/" 2>/dev/null || true
        spinner_stop "ok" "Configuration saved"
    fi
    
    # backup database
    if [[ "$SKIP_DATABASE" == false ]]; then
        # find mysqldump
        DUMP_CMD=""
        for cmd in mysqldump mariadb-dump; do
            command -v "$cmd" >/dev/null 2>&1 && { DUMP_CMD="$cmd"; break; }
        done
        
        if [[ -n "$DUMP_CMD" ]]; then
            spinner_start "Backing up database" 15
            if "$DUMP_CMD" "${MYSQL_ROOT_ARGS[@]}" "$DB_NAME" > "$BACKUP_DIR/database.sql" 2>/dev/null; then
                spinner_stop "ok" "Database saved"
            else
                spinner_stop "skip" "Database backup failed (may not exist)"
            fi
        else
            warn "mysqldump not found, skipping database backup"
        fi
    else
        warn "Skipping database backup ($SKIP_REASON)"
    fi
    
    success "Backup location: $BACKUP_DIR"
fi

# drop database
header "Removing Database"

if [[ "$SKIP_DATABASE" == false ]]; then
    spinner_start "Dropping database and user" 3
    "$MYSQL_CMD" "${MYSQL_ROOT_ARGS[@]}" <<EOF || true
DROP DATABASE IF EXISTS \`$DB_NAME\`;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    spinner_stop "ok" "Dropped database '$DB_NAME' and user '$DB_USER'"
else
    warn "Skipping database removal ($SKIP_REASON)"
    warn "Database '$DB_NAME' and user '$DB_USER' may still exist"
fi

# stop services
header "Stopping Services"

stop_if() { 
    systemctl stop "$1" 2>/dev/null || true
    systemctl disable "$1" 2>/dev/null || true
}

for svc in zabbix-server zabbix-agent zabbix-agent2; do
    run "Stopping $svc" 2 stop_if "$svc"
done

if [[ "$PURGE_ALL" =~ ^[Yy]$ ]]; then
    for svc in apache2 "php${PHP_VER}-fpm" php-fpm mariadb mysql snmpd; do
        run "Stopping $svc" 2 stop_if "$svc"
    done
fi

# fix broken packages
dpkg --configure -a 2>/dev/null || true
apt --fix-broken install -y 2>/dev/null || true

# remove zabbix
header "Removing Zabbix"

spinner_start "Removing Zabbix files" 3
rm -rf /var/log/zabbix \
       /var/lib/zabbix \
       /var/run/zabbix \
       /run/zabbix \
       /usr/share/zabbix \
       /usr/share/doc/zabbix* \
       /etc/zabbix/web/zabbix.conf.php \
       /usr/share/zabbix/sql-scripts \
       /etc/zabbix/zabbix_agentd.d \
       /usr/share/zabbix-* \
       /var/cache/zabbix \
       /tmp/zabbix* \
       /tmp/zabbix*.deb \
       /var/cache/apt/archives/zabbix*.deb 2>/dev/null || true
rm -f /etc/apache2/conf-available/zabbix.conf \
      /etc/apache2/conf-enabled/zabbix.conf \
      /etc/apache2/conf-available/zabbix-override.conf \
      /etc/apache2/conf-enabled/zabbix-override.conf \
      /etc/logrotate.d/zabbix* \
      /etc/default/zabbix* \
      /etc/init.d/zabbix* \
      /lib/systemd/system/zabbix*.service \
      /etc/systemd/system/zabbix*.service \
      /etc/systemd/system/multi-user.target.wants/zabbix*.service 2>/dev/null || true
spinner_stop "ok" "Removing Zabbix files"

INSTALLED_ZBX=($(dpkg -l | awk '/^ii|^iF|^iU/ {print $2}' | grep -E '^zabbix-' || true))
if [[ ${#INSTALLED_ZBX[@]} -gt 0 ]]; then
    run "Purging Zabbix packages" 20 apt purge -y "${INSTALLED_ZBX[@]}"
else
    success "No Zabbix packages to remove"
fi

# reload systemd after removing service files
systemctl daemon-reload 2>/dev/null || true

spinner_start "Removing Zabbix repository" 10
rm -f /etc/apt/sources.list.d/zabbix*.list \
      /etc/apt/trusted.gpg.d/zabbix*.gpg \
      /usr/share/keyrings/zabbix*.gpg \
      /etc/apt/sources.list.d/zabbix*.sources \
      /var/cache/apt/archives/zabbix*.deb \
      /var/cache/apt/archives/partial/zabbix*.deb 2>/dev/null || true
# remove zabbix key from apt-key if present
apt-key del "$(apt-key list 2>/dev/null | grep -B1 -i zabbix | head -1 | awk '{print $NF}')" 2>/dev/null || true
apt update -y >/dev/null 2>&1 || true
spinner_stop "ok" "Removing Zabbix repository"

# purge auxiliary stack
if [[ "$PURGE_ALL" =~ ^[Yy]$ ]]; then
    header "Removing Auxiliary Stack"
    
    spinner_start "Removing auxiliary files" 5
    rm -rf /var/lib/apache2 /var/cache/apache2 /var/log/apache2 /etc/apache2 /var/www/html \
           /etc/php /var/lib/php /var/log/php* /run/php \
           /var/lib/mysql /var/log/mysql* /etc/mysql /run/mysqld /var/cache/mysql \
           /etc/snmp /var/lib/snmp /var/log/snmpd.log 2>/dev/null || true
    spinner_stop "ok" "Removing auxiliary files"
    
    AUX_PKGS=(
        # apache
        apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php "libapache2-mod-php${PHP_VER}"
        # mariadb
        mariadb-server mariadb-client mariadb-common mariadb-server-core mariadb-client-core mysql-common galera-4
        # php
        php php-cli php-fpm php-mysql php-xml php-bcmath php-mbstring php-ldap php-gd php-zip php-curl php-common
        "php${PHP_VER}" "php${PHP_VER}-cli" "php${PHP_VER}-fpm" "php${PHP_VER}-mysql" "php${PHP_VER}-xml"
        "php${PHP_VER}-bcmath" "php${PHP_VER}-mbstring" "php${PHP_VER}-ldap" "php${PHP_VER}-gd" "php${PHP_VER}-zip"
        "php${PHP_VER}-curl" "php${PHP_VER}-common" "php${PHP_VER}-opcache" "php${PHP_VER}-readline"
        # tools
        wget curl gnupg2 jq apt-transport-https rsync socat ssl-cert fping snmpd snmp-mibs-downloader
    )
    
    INSTALLED_AUX=($(dpkg -l | awk '/^ii|^iF|^iU/ {print $2}' | grep -x -F -f <(printf "%s\n" "${AUX_PKGS[@]}") || true))
    if [[ ${#INSTALLED_AUX[@]} -gt 0 ]]; then
        run "Purging auxiliary packages" 45 apt purge -y "${INSTALLED_AUX[@]}"
    else
        success "No auxiliary packages to remove"
    fi
    
    # final cleanup
    spinner_start "Final file cleanup" 3
    rm -rf /var/lib/apache2 /var/cache/apache2 /var/log/apache2 /etc/apache2 /var/www/html \
           /etc/php /var/lib/php /var/log/php* /run/php \
           /var/lib/mysql /var/log/mysql* /etc/mysql /run/mysqld /var/cache/mysql \
           /etc/snmp /var/lib/snmp /var/log/snmpd.log \
           /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/* 2>/dev/null || true
    spinner_stop "ok" "Final file cleanup"
    
    # reload systemd
    systemctl daemon-reload 2>/dev/null || true
fi

# final cleanup
header "Finishing Up"

run "Removing Zabbix config directory" 2 rm -rf /etc/zabbix
rm -f /root/.zabbix-credentials /var/tmp/.zabbix-installer-state 2>/dev/null || true

dpkg --configure -a 2>/dev/null || true
apt --fix-broken install -y 2>/dev/null || true
run "Cleaning up packages" 15 apt autoremove -y
apt autoclean -y >/dev/null 2>&1 || true
apt clean >/dev/null 2>&1 || true

# offer to remove log file
if [[ -f "$LOG_FILE" ]]; then
    echo
    echo -ne "  ${CYAN}?${NC} Remove installer log file? ${DIM}[y/N]${NC}: "
    read -r remove_log
    if [[ "$remove_log" =~ ^[Yy]$ ]]; then
        rm -f "$LOG_FILE"
        success "Removed $LOG_FILE"
        LOG_FILE=""
    fi
fi

# done
echo
echo -e "${BOLD}${GREEN}  Uninstall Complete${NC}"
divider
if [[ "$DO_BACKUP" =~ ^[Yy]$ ]] && [[ -d "${BACKUP_DIR:-}" ]]; then
    echo -e "  ${DIM}Backup:${NC}           $BACKUP_DIR"
fi
if [[ "$SKIP_DATABASE" == false ]]; then
    echo -e "  ${DIM}Database dropped:${NC} $DB_NAME"
    echo -e "  ${DIM}User dropped:${NC}     $DB_USER"
else
    echo -e "  ${YELLOW}Database:${NC}         $DB_NAME ${DIM}(not dropped - $SKIP_REASON)${NC}"
    echo -e "  ${YELLOW}User:${NC}             $DB_USER ${DIM}(not dropped)${NC}"
fi
if [[ "$PURGE_ALL" =~ ^[Yy]$ ]]; then
    echo -e "  ${DIM}Auxiliary stack:${NC}  Removed"
fi
divider
if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    echo -e "  ${DIM}Log file: $LOG_FILE${NC}"
fi
echo

if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    echo "=== Zabbix Uninstaller completed: $(date) ==="  >> "$LOG_FILE"
fi
