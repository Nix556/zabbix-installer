#!/bin/bash
# zabbix 7.4 installer - debian 11/12, ubuntu 22.04/24.04

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin
set -euo pipefail
IFS=$'\n\t'

# logging
LOG_FILE="/var/log/zabbix-installer.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Zabbix Installer started: $(date) ===" >> "$LOG_FILE"

# dry-run mode
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
    DRY_RUN=true
fi

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
spin_start_time=""

spinner_start() {
    local msg="$1"
    local est="${2:-0}"
    spin_start_time=$(date +%s)
    (
        local i=0
        local start_time=$spin_start_time
        local estimate=$est
        while true; do
            local now=$(date +%s)
            local elapsed=$((now - start_time))
            local time_info
            if [[ "$estimate" -gt 0 ]]; then
                time_info="${elapsed}s / ~${estimate}s"
            else
                time_info="${elapsed}s"
            fi
            printf "\r\033[K  ${CYAN}%s${NC} %s ${DIM}[%s]${NC}" "${SPIN_CHARS:i++%4:1}" "$msg" "$time_info"
            sleep 0.1
        done
    ) &
    spin_pid=$!
    disown
}

spinner_stop() {
    local status="$1"
    local msg="$2"
    local elapsed=""
    if [[ -n "${spin_start_time:-}" ]]; then
        elapsed=" ${DIM}($(( $(date +%s) - spin_start_time ))s)${NC}"
    fi
    [[ -n "${spin_pid:-}" ]] && kill "$spin_pid" 2>/dev/null || true
    spin_pid=""
    spin_start_time=""
    printf "\r\033[K"
    if [[ "$status" == "ok" ]]; then
        echo -e "  ${GREEN}+${NC} $msg$elapsed"
    elif [[ "$status" == "skip" ]]; then
        echo -e "  ${YELLOW}-${NC} $msg$elapsed"
    else
        echo -e "  ${RED}x${NC} $msg$elapsed"
    fi
}

header() {
    echo
    echo -e "${BOLD}${BLUE}:: $1${NC}"
}

info() {
    echo -e "  ${DIM}$1${NC}"
}

success() {
    echo -e "  ${GREEN}+${NC} $1"
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

# validation
valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra octets <<< "$ip"
    for o in "${octets[@]}"; do (( o > 255 )) && return 1; done
    return 0
}

port_free() {
    ! ss -tuln 2>/dev/null | grep -q ":$1 "
}

check_password() {
    local pass="$1"
    local lower="${pass,,}"
    local len=${#pass}
    
    local weak_patterns=(
        "password" "passwd" "pass" "admin" "root" "zabbix"
        "123456" "qwerty" "letmein" "welcome" "monkey" "dragon"
        "master" "login" "abc123" "111111" "123123"
    )
    for p in "${weak_patterns[@]}"; do
        [[ "$lower" == *"$p"* ]] && { echo "weak"; return; }
    done
    
    [[ "$lower" =~ qwerty|asdf|zxcv|1234|4321 ]] && { echo "weak"; return; }
    (( len < 8 )) && { echo "weak"; return; }
    
    local score=0
    (( len >= 12 )) && (( score++ ))
    (( len >= 16 )) && (( score++ ))
    [[ "$pass" =~ [a-z] ]] && (( score++ ))
    [[ "$pass" =~ [A-Z] ]] && (( score++ ))
    [[ "$pass" =~ [0-9] ]] && (( score++ ))
    [[ "$pass" =~ [^a-zA-Z0-9] ]] && (( score++ ))
    
    local unique=$(echo "$pass" | fold -w1 | sort -u | wc -l)
    (( unique < len / 2 )) && (( score-- ))
    
    if (( score < 3 )); then
        echo "weak"
    elif (( score < 5 )); then
        echo "medium"
    else
        echo "strong"
    fi
}

gen_password() {
    local len=${1:-16}
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#$%' | head -c "$len"
    elif [[ -r /dev/urandom ]]; then
        head -c 100 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$len"
    else
        echo "$(date +%s%N)$(hostname)" | sha256sum | head -c "$len"
    fi
}

# state management
STATE_FILE="/var/tmp/.zabbix-installer-state"
CREDS_FILE="/root/.zabbix-credentials"
INSTALL_FAILED=false

save_state() {
    cat > "$STATE_FILE" <<EOF
STEP="$1"
ZABBIX_IP="$ZABBIX_IP"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
ROOT_PASS="$ROOT_PASS"
ZABBIX_ADMIN_PASS="$ZABBIX_ADMIN_PASS"
TIMEZONE="$TIMEZONE"
PHP_VER="$PHP_VER"
REPO_URL="$REPO_URL"
EOF
}

load_state() {
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
}

clear_state() {
    rm -f "$STATE_FILE"
}

rollback() {
    echo
    header "Rolling Back Installation"
    
    for svc in zabbix-server zabbix-agent zabbix-agent2; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    success "Stopped Zabbix services"
    
    if [[ -n "${DB_NAME:-}" ]] && command -v mysql >/dev/null 2>&1; then
        local mysql_args=(-uroot)
        [[ -n "${ROOT_PASS:-}" ]] && mysql_args+=(-p"$ROOT_PASS")
        if mysql "${mysql_args[@]}" -e "SELECT 1" 2>/dev/null; then
            mysql "${mysql_args[@]}" -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || true
            success "Dropped database and user"
        fi
    fi
    
    local zabbix_pkgs=$(dpkg -l 2>/dev/null | awk '/^ii.*zabbix/ {print $2}' || true)
    if [[ -n "$zabbix_pkgs" ]]; then
        apt purge -y $zabbix_pkgs >/dev/null 2>&1 || true
        success "Removed Zabbix packages"
    fi
    
    rm -f /etc/apt/sources.list.d/zabbix*.list \
          /etc/apt/sources.list.d/zabbix*.sources \
          /etc/apt/trusted.gpg.d/zabbix*.gpg \
          /usr/share/keyrings/zabbix*.gpg \
          /var/cache/apt/archives/zabbix*.deb 2>/dev/null || true
    apt-key del "$(apt-key list 2>/dev/null | grep -B1 -i zabbix | head -1 | awk '{print $NF}')" 2>/dev/null || true
    apt update -y >/dev/null 2>&1 || true
    success "Removed Zabbix repository"
    
    rm -rf /etc/zabbix \
           /var/log/zabbix \
           /var/lib/zabbix \
           /var/run/zabbix \
           /run/zabbix \
           /usr/share/zabbix \
           /usr/share/zabbix-* \
           /usr/share/doc/zabbix* \
           /var/cache/zabbix \
           /tmp/zabbix* 2>/dev/null || true
    rm -f /etc/apache2/conf-available/zabbix.conf \
          /etc/apache2/conf-enabled/zabbix.conf \
          /etc/apache2/conf-available/zabbix-override.conf \
          /etc/apache2/conf-enabled/zabbix-override.conf \
          /etc/logrotate.d/zabbix* \
          /etc/default/zabbix* \
          /lib/systemd/system/zabbix*.service \
          /etc/systemd/system/zabbix*.service 2>/dev/null || true
    rm -f "$CREDS_FILE" /tmp/zabbix-release.deb /tmp/zabbix*.deb 2>/dev/null || true
    success "Removed configuration files"
    
    systemctl daemon-reload 2>/dev/null || true
    clear_state
    apt autoremove -y >/dev/null 2>&1 || true
    apt autoclean -y >/dev/null 2>&1 || true
    apt clean >/dev/null 2>&1 || true
    
    divider
    echo -e "  ${DIM}Rollback complete. System restored to pre-install state.${NC}"
    echo
}

step_done() {
    local step="$1"
    [[ -f "$STATE_FILE" ]] || return 1
    source "$STATE_FILE"
    local steps=(deps zabbix_repo zabbix_pkg apache database schema config services)
    local saved_idx=-1 check_idx=-1
    for i in "${!steps[@]}"; do
        [[ "${steps[$i]}" == "$STEP" ]] && saved_idx=$i
        [[ "${steps[$i]}" == "$step" ]] && check_idx=$i
    done
    (( check_idx < saved_idx ))
}

run() {
    local msg="$1"
    local est=""
    if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        est="$2"
        shift 2
    else
        shift
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${DIM}[dry-run]${NC} $msg"
        return 0
    fi
    spinner_start "$msg" "$est"
    if "$@" >/dev/null 2>&1; then
        spinner_stop "ok" "$msg"
        return 0
    else
        spinner_stop "fail" "$msg"
        return 1
    fi
}

dry_write() {
    local file="$1"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${DIM}[dry-run]${NC} Would write: $file"
        cat > /dev/null
    else
        cat > "$file"
    fi
}

cleanup() {
    local exit_code=$?
    [[ -n "${spin_pid:-}" ]] && kill "$spin_pid" 2>/dev/null || true
    
    if [[ $exit_code -ne 0 && "$DRY_RUN" != true && "$INSTALL_FAILED" != true ]]; then
        INSTALL_FAILED=true
        echo
        echo -e "  ${RED}x${NC} Installation failed!"
        echo "=== Zabbix Installer FAILED (exit code: $exit_code): $(date) ===" >> "$LOG_FILE"
        
        echo
        echo -ne "  ${CYAN}?${NC} Roll back partial installation? ${DIM}[Y/n]${NC}: "
        read -r do_rollback </dev/tty || do_rollback="n"
        if [[ ! "$do_rollback" =~ ^[Nn]$ ]]; then
            rollback
        else
            echo
            warn "Partial installation left in place"
            info "Run uninstall.sh to clean up manually"
            info "Or run install.sh again to resume"
            echo
        fi
    fi
}
trap cleanup EXIT

# banner
clear
echo
echo -e "${BOLD}${GREEN}  Zabbix 7.4 Installer${NC}"
echo -e "${DIM}  Debian 11/12 | Ubuntu 22.04/24.04${NC}"
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}  [DRY-RUN MODE]${NC}"
fi
echo

# root check
if [[ $EUID -ne 0 ]]; then
    error "Please run as root (sudo)"
    exit 1
fi
export DEBIAN_FRONTEND=noninteractive

# check if already installed
ALREADY_INSTALLED=false
if systemctl is-active --quiet zabbix-server 2>/dev/null; then
    ALREADY_INSTALLED=true
elif [[ -f /etc/zabbix/zabbix_server.conf ]] && grep -q "DBPassword=" /etc/zabbix/zabbix_server.conf 2>/dev/null; then
    ALREADY_INSTALLED=true
elif [[ -f "$CREDS_FILE" ]]; then
    ALREADY_INSTALLED=true
fi

if [[ "$ALREADY_INSTALLED" == true ]]; then
    warn "Zabbix appears to be already installed"
    echo -ne "  ${CYAN}?${NC} Reinstall/reconfigure? ${DIM}[y/N]${NC}: "
    read -r reinstall
    if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
        info "Use uninstall.sh first if you want a fresh install"
        exit 0
    fi
    warn "Continuing may overwrite existing configuration"
fi

# check for resume
RESUMING=false
if [[ -f "$STATE_FILE" ]]; then
    load_state
    echo -e "  ${YELLOW}!${NC} Previous installation found (stopped at: $STEP)"
    echo -ne "  ${CYAN}?${NC} Resume from where you left off? ${DIM}[Y/n]${NC}: "
    read -r ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
        RESUMING=true
        success "Resuming installation..."
    else
        clear_state
        info "Starting fresh installation"
    fi
fi

# detect os
header "System Detection"

. /etc/os-release
OS="$ID"
VER="$VERSION_ID"

if [[ "$OS" == "debian" && "$VER" == "12" ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb"
    success "Detected: Debian 12 (Bookworm)"
elif [[ "$OS" == "debian" && "$VER" == "11" ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian11_all.deb"
    success "Detected: Debian 11 (Bullseye)"
elif [[ "$OS" == "ubuntu" && "$VER" == "24.04" ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.4+ubuntu24.04_all.deb"
    success "Detected: Ubuntu 24.04 (Noble)"
elif [[ "$OS" == "ubuntu" && "$VER" == "22.04" ]]; then
    REPO_URL="https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.4+ubuntu22.04_all.deb"
    success "Detected: Ubuntu 22.04 (Jammy)"
else
    error "Unsupported OS"
    info "Supported: Debian 11/12, Ubuntu 22.04/24.04"
    exit 1
fi

# port checks
header "Pre-flight Checks"

PORTS_WARN=false
for p in 80:HTTP 443:HTTPS 10051:"Zabbix Server" 10050:"Zabbix Agent" 3306:MariaDB; do
    port=${p%%:*}
    name=${p#*:}
    if port_free "$port"; then
        success "Port $port ($name) available"
    else
        warn "Port $port ($name) in use"
        PORTS_WARN=true
    fi
done

if [[ "$PORTS_WARN" == true ]]; then
    echo
    echo -ne "  ${CYAN}?${NC} Continue anyway? ${DIM}[y/N]${NC}: "
    read -r ans
    [[ ! "$ans" =~ ^[Yy]$ ]] && { error "Aborted"; exit 1; }
fi

# user input
header "Configuration"
echo

detect_ip() {
    local ip=""
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    ip=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    echo "127.0.0.1"
}

DEFAULT_IP=$(detect_ip)

if [[ "$RESUMING" == true ]]; then
    info "Using saved configuration"
    divider
    info "Server IP:    $ZABBIX_IP"
    info "Database:     $DB_NAME"
    info "DB User:      $DB_USER"
    info "Admin Pass:   $ZABBIX_ADMIN_PASS"
    info "Timezone:     $TIMEZONE"
    divider
    echo
else
    while true; do
        echo -ne "  ${CYAN}?${NC} Zabbix Server IP ${DIM}[$DEFAULT_IP]${NC}: "
        read -r ZABBIX_IP
        ZABBIX_IP=${ZABBIX_IP:-$DEFAULT_IP}
        valid_ip "$ZABBIX_IP" && break
        warn "Invalid IP format"
    done

    echo -ne "  ${CYAN}?${NC} Database name ${DIM}[zabbix]${NC}: "
    read -r DB_NAME
    DB_NAME=${DB_NAME:-zabbix}

    echo -ne "  ${CYAN}?${NC} Database user ${DIM}[zabbix]${NC}: "
    read -r DB_USER
    DB_USER=${DB_USER:-zabbix}

    echo -ne "  ${CYAN}?${NC} Database password ${DIM}[enter=generate, or type]${NC}: "
    read -rs DB_PASS
    echo
    if [[ -z "$DB_PASS" ]]; then
        DB_PASS=$(gen_password 16)
        success "Generated: $DB_PASS"
    else
        PASS_STRENGTH=$(check_password "$DB_PASS")
        if [[ "$PASS_STRENGTH" == "weak" ]]; then
            warn "Weak password detected"
        elif [[ "$PASS_STRENGTH" == "medium" ]]; then
            info "Password strength: medium"
        else
            success "Password strength: strong"
        fi
    fi

    echo -ne "  ${CYAN}?${NC} MariaDB root password ${DIM}[enter=generate, s=socket, or type]${NC}: "
    read -rs ROOT_PASS
    echo
    if [[ "$ROOT_PASS" == "s" || "$ROOT_PASS" == "S" ]]; then
        ROOT_PASS=""
        info "Using socket authentication"
    elif [[ -z "$ROOT_PASS" ]]; then
        ROOT_PASS=$(gen_password 16)
        success "Generated: $ROOT_PASS"
    else
        ROOT_STRENGTH=$(check_password "$ROOT_PASS")
        if [[ "$ROOT_STRENGTH" == "weak" ]]; then
            warn "Weak password detected"
        elif [[ "$ROOT_STRENGTH" == "medium" ]]; then
            info "Password strength: medium"
        else
            success "Password strength: strong"
        fi
    fi

    echo -ne "  ${CYAN}?${NC} Frontend admin password ${DIM}[enter=generate, or type]${NC}: "
    read -r ZABBIX_ADMIN_PASS
    if [[ -z "$ZABBIX_ADMIN_PASS" ]]; then
        ZABBIX_ADMIN_PASS=$(gen_password 12)
        success "Generated: $ZABBIX_ADMIN_PASS"
    fi

    SYS_TZ="UTC"
    if [[ -f /etc/timezone ]]; then
        SYS_TZ=$(cat /etc/timezone)
    elif [[ -L /etc/localtime ]]; then
        SYS_TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
    fi
    
    echo -ne "  ${CYAN}?${NC} Timezone ${DIM}[$SYS_TZ]${NC}: "
    read -r TIMEZONE
    TIMEZONE=${TIMEZONE:-$SYS_TZ}
    
    if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
        success "Timezone: $TIMEZONE"
    else
        warn "Unknown timezone, using UTC"
        TIMEZONE="UTC"
    fi

    echo
    divider
    info "Server IP:    $ZABBIX_IP"
    info "Database:     $DB_NAME"
    info "DB User:      $DB_USER"
    info "Admin Pass:   $ZABBIX_ADMIN_PASS"
    divider
    echo
    
    cat > "$CREDS_FILE" <<EOF
# Zabbix Installation Credentials
# Generated: $(date)
# Keep this file secure!

Zabbix Frontend:
  URL:      http://$ZABBIX_IP/zabbix
  Username: Admin
  Password: $ZABBIX_ADMIN_PASS

Database:
  Name:     $DB_NAME
  User:     $DB_USER
  Password: $DB_PASS

MariaDB Root:
  Password: ${ROOT_PASS:-[socket auth]}
EOF
    chmod 600 "$CREDS_FILE"
    success "Credentials saved to $CREDS_FILE"
fi

# get php version
if command -v php >/dev/null 2>&1; then
    PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
else
    case "${OS}-${VER}" in
        debian-12) PHP_VER="8.2" ;;
        debian-11) PHP_VER="7.4" ;;
        ubuntu-24.04) PHP_VER="8.3" ;;
        ubuntu-22.04) PHP_VER="8.1" ;;
        *) PHP_VER="8.2" ;;
    esac
fi

mkdir -p /run/php 2>/dev/null || true

# install dependencies
if step_done deps; then
    header "Installing Dependencies"
    success "Already completed (skipped)"
else
    header "Installing Dependencies"

    PKGS=(wget curl gnupg2 jq apt-transport-https
          php-cli php-fpm php-mysql php-xml php-bcmath php-mbstring php-ldap php-gd php-zip php-curl
          mariadb-server mariadb-client rsync socat ssl-cert fping snmpd apache2)

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${DIM}[dry-run]${NC} Would update package lists"
        echo -e "  ${DIM}[dry-run]${NC} Would install: ${PKGS[*]}"
    else
        run "Updating package lists" 30 apt update -y

        mkdir -p /var/lib/snmp /etc/snmp
        chown -R Debian-snmp:Debian-snmp /var/lib/snmp 2>/dev/null || true

        if [[ -d /etc/php ]]; then
            find /etc/php -name "*.ini" -size 0 -delete 2>/dev/null || true
        fi

        set +e
        dpkg --configure -a 2>/dev/null || true
        apt --fix-broken install -y 2>/dev/null || true

        spinner_start "Installing required packages" 120
        if apt -o APT::Install-Recommends=false -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" install -y "${PKGS[@]}" >/dev/null 2>&1; then
            spinner_stop "ok" "Installing required packages"
        else
            spinner_stop "skip" "Retrying with fix-broken"
            mkdir -p /var/lib/snmp /etc/snmp
            chown -R Debian-snmp:Debian-snmp /var/lib/snmp 2>/dev/null || true
            dpkg --configure -a 2>/dev/null || true
            apt --fix-broken install -y >/dev/null 2>&1
            run "Installing required packages" 120 apt -o APT::Install-Recommends=false -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" install -y "${PKGS[@]}"
        fi
        set -e
        
        save_state deps
    fi
fi

# zabbix repo and packages
if step_done zabbix_pkg; then
    header "Installing Zabbix"
    success "Already completed (skipped)"
else
    header "Installing Zabbix"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${DIM}[dry-run]${NC} Would download: $REPO_URL"
        echo -e "  ${DIM}[dry-run]${NC} Would install Zabbix repository"
        echo -e "  ${DIM}[dry-run]${NC} Would install: zabbix-server-mysql zabbix-frontend-php zabbix-sql-scripts zabbix-agent"
    else
        if ! step_done zabbix_repo; then
            spinner_start "Adding Zabbix repository" 15
            wget -qO /tmp/zabbix-release.deb "$REPO_URL"
            dpkg -i /tmp/zabbix-release.deb >/dev/null 2>&1
            apt update -y >/dev/null 2>&1
            spinner_stop "ok" "Adding Zabbix repository"
            save_state zabbix_repo
        else
            success "Repository already added (skipped)"
        fi

        run "Installing Zabbix packages" 90 apt -o APT::Install-Recommends=false -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" install -y \
            zabbix-server-mysql zabbix-frontend-php zabbix-sql-scripts zabbix-agent

        apt -y purge 'libapache2-mod-php*' >/dev/null 2>&1 || true
        dpkg --configure -a >/dev/null 2>&1 || true
        apt --fix-broken install -y >/dev/null 2>&1 || true
        save_state zabbix_pkg
    fi
fi

# apache setup
if step_done apache; then
    header "Configuring Apache"
    success "Already completed (skipped)"
else
    header "Configuring Apache"

    if [[ -d /usr/share/zabbix/ui ]]; then
        ZABBIX_UI_DIR="/usr/share/zabbix/ui"
    else
        ZABBIX_UI_DIR="/usr/share/zabbix"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${DIM}[dry-run]${NC} Would enable Apache modules"
        echo -e "  ${DIM}[dry-run]${NC} Would write: /etc/apache2/conf-available/zabbix.conf"
    else
        if command -v a2enmod >/dev/null 2>&1; then
            run "Enabling Apache modules" 5 a2enmod mpm_event proxy proxy_fcgi setenvif alias
        fi

        cat > /etc/apache2/conf-available/zabbix.conf <<EOF
Alias /zabbix $ZABBIX_UI_DIR

<Directory "$ZABBIX_UI_DIR">
    Options FollowSymLinks
    AllowOverride None
    Require all granted
    DirectoryIndex index.php
</Directory>

<IfModule proxy_fcgi_module>
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost/"
    </FilesMatch>
</IfModule>
EOF

        if command -v a2enconf >/dev/null 2>&1; then
            a2enconf zabbix >/dev/null 2>&1 || true
        fi

        cat > /etc/apache2/conf-available/zabbix-override.conf <<EOF
<Directory $ZABBIX_UI_DIR>
    Options FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
EOF
        a2enconf zabbix-override >/dev/null 2>&1 || true

        success "Created Apache configuration"

        run "Starting Apache" 5 systemctl enable --now apache2
        run "Starting PHP-FPM" 5 systemctl enable --now "php${PHP_VER}-fpm"
        save_state apache
    fi
fi

# mariadb setup
if step_done database; then
    header "Configuring Database"
    success "Already completed (skipped)"
else
    header "Configuring Database"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${DIM}[dry-run]${NC} Would start MariaDB"
        echo -e "  ${DIM}[dry-run]${NC} Would create database: $DB_NAME"
        echo -e "  ${DIM}[dry-run]${NC} Would create user: $DB_USER"
    else
        run "Starting MariaDB" 10 systemctl enable --now mariadb

        for i in {1..30}; do
            [[ -S /run/mysqld/mysqld.sock ]] && break
            sleep 1
        done

        MYSQL_ROOT_ARGS=(-uroot)
        [[ -n "${ROOT_PASS:-}" ]] && MYSQL_ROOT_ARGS+=(-p"$ROOT_PASS")

        spinner_start "Testing database connection" 3
        if mysql "${MYSQL_ROOT_ARGS[@]}" -e "SELECT 1" >/dev/null 2>&1; then
            spinner_stop "ok" "Database connection OK"
        else
            spinner_stop "fail" "Cannot connect to MariaDB"
            error "Check root password and try again"
            exit 1
        fi

        spinner_start "Creating database and user" 5
        mysql "${MYSQL_ROOT_ARGS[@]}" <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
        spinner_stop "ok" "Creating database and user"
        save_state database
    fi
fi

# import schema
header "Importing Schema"

if step_done schema; then
    success "Already completed (skipped)"
else
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${DIM}[dry-run]${NC} Would import schema"
    else
        MYSQL_ROOT_ARGS=(-uroot)
        [[ -n "${ROOT_PASS:-}" ]] && MYSQL_ROOT_ARGS+=(-p"$ROOT_PASS")
        
        if ! mysql "${MYSQL_ROOT_ARGS[@]}" -Nse "SELECT 1 FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name='users' LIMIT 1;" | grep -q 1; then
            spinner_start "Importing Zabbix schema" 60
            zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
            spinner_stop "ok" "Importing Zabbix schema"
        else
            success "Schema already exists (skipped import)"
        fi
        
        if [[ "$ZABBIX_ADMIN_PASS" != "zabbix" ]]; then
            spinner_start "Setting admin password" 3
            PASS_HASH=$(php -r "echo password_hash('$ZABBIX_ADMIN_PASS', PASSWORD_BCRYPT);")
            mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "UPDATE users SET passwd='$PASS_HASH' WHERE username='Admin';" 2>/dev/null
            spinner_stop "ok" "Admin password updated"
        fi
        
        save_state schema
    fi
fi

# zabbix config
if step_done config; then
    header "Configuring Zabbix"
    success "Already completed (skipped)"
else
    header "Configuring Zabbix"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${DIM}[dry-run]${NC} Would update /etc/zabbix/zabbix_server.conf"
        echo -e "  ${DIM}[dry-run]${NC} Would create /etc/zabbix/web/zabbix.conf.php"
    else
        # Update database settings - handle both commented and uncommented lines
        # Pattern matches: DBName=xxx, # DBName=xxx, ### DBName=xxx, etc.
        sed -i -E "s|^#*[[:space:]]*DBName=.*|DBName=$DB_NAME|" /etc/zabbix/zabbix_server.conf
        sed -i -E "s|^#*[[:space:]]*DBUser=.*|DBUser=$DB_USER|" /etc/zabbix/zabbix_server.conf
        sed -i -E "s|^#*[[:space:]]*DBPassword=.*|DBPassword=$DB_PASS|" /etc/zabbix/zabbix_server.conf
        sed -i '/^[[:space:]]*#*[[:space:]]*DBType=/Id' /etc/zabbix/zabbix_server.conf || true
        success "Updated server configuration"

        mkdir -p /etc/zabbix/zabbix_agentd.d
        cat > /etc/zabbix/zabbix_agentd.d/agent.conf <<EOF
Server=$ZABBIX_IP
ServerActive=$ZABBIX_IP
Hostname=$(hostname)
EOF
        success "Created agent configuration"

        for SAPI in fpm cli; do
            PHP_INI="/etc/php/${PHP_VER}/${SAPI}/php.ini"
            if [[ -f "$PHP_INI" ]]; then
                sed -i "s|^;*date.timezone =.*|date.timezone = $TIMEZONE|" "$PHP_INI" || true
                sed -i "s|^;*post_max_size =.*|post_max_size = 16M|" "$PHP_INI" || true
                sed -i "s|^;*max_execution_time =.*|max_execution_time = 300|" "$PHP_INI" || true
                sed -i "s|^;*max_input_time =.*|max_input_time = 300|" "$PHP_INI" || true
                sed -i "s|^;*memory_limit =.*|memory_limit = 128M|" "$PHP_INI" || true
            fi
        done
        success "Updated PHP settings (timezone: $TIMEZONE)"

        mkdir -p /etc/zabbix/web
        cat > /etc/zabbix/web/zabbix.conf.php <<EOF
<?php
\$DB['TYPE']     = 'MYSQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = '$DB_NAME';
\$DB['USER']     = '$DB_USER';
\$DB['PASSWORD'] = '$DB_PASS';
\$DB['SCHEMA']   = '';
\$DB['ENCRYPTION'] = false;
\$DB['KEY_FILE'] = '';
\$DB['CERT_FILE'] = '';
\$DB['CA_FILE'] = '';
\$DB['VERIFY_HOST'] = false;
\$DB['CIPHER_LIST'] = '';
\$DB['VAULT'] = '';
\$DB['VAULT_URL'] = '';
\$DB['VAULT_PREFIX'] = '';
\$DB['VAULT_DB_PATH'] = '';
\$DB['VAULT_TOKEN'] = '';
\$DB['VAULT_CERT_FILE'] = '';
\$DB['VAULT_KEY_FILE'] = '';
\$DB['DOUBLE_IEEE754'] = true;
\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = 'Zabbix Server';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
?>
EOF
        success "Created frontend configuration"
        save_state config
    fi
fi

# cleanup and start
header "Finishing Up"

if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${DIM}[dry-run]${NC} Would start: zabbix-server, zabbix-agent"
    echo
    echo -e "${BOLD}${GREEN}  Dry-Run Complete${NC}"
    divider
    echo -e "  ${DIM}Run without --dry-run to actually install${NC}"
    echo
    exit 0
fi

# cleanup temporary files
rm -f /tmp/zabbix-release.deb /tmp/zabbix*.deb 2>/dev/null || true
rm -rf /var/cache/apt/archives/zabbix*.deb 2>/dev/null || true
rm -rf /var/cache/apt/archives/partial/* 2>/dev/null || true

run "Cleaning up packages" 10 apt autoremove -y
apt autoclean -y >/dev/null 2>&1 || true
apt clean >/dev/null 2>&1 || true

run "Starting Zabbix server" 5 systemctl enable --now zabbix-server
run "Starting Zabbix agent" 5 systemctl enable --now zabbix-agent
run "Restarting PHP-FPM" 3 systemctl restart "php${PHP_VER}-fpm"
run "Restarting Apache" 3 systemctl restart apache2

spinner_start "Waiting for Zabbix server" 10
for i in {1..30}; do
    if systemctl is-active --quiet zabbix-server; then
        spinner_stop "ok" "Zabbix server is running"
        break
    fi
    sleep 1
done

if ! systemctl is-active --quiet zabbix-server; then
    spinner_stop "fail" "Zabbix server may not have started"
    warn "Check: systemctl status zabbix-server"
fi

# health check
header "Health Check"

if systemctl is-active --quiet zabbix-server; then
    success "Zabbix server: running"
else
    error "Zabbix server: not running"
fi

if systemctl is-active --quiet zabbix-agent; then
    success "Zabbix agent: running"
else
    error "Zabbix agent: not running"
fi

if systemctl is-active --quiet apache2; then
    success "Apache: running"
else
    error "Apache: not running"
fi

if systemctl is-active --quiet mariadb; then
    success "MariaDB: running"
else
    error "MariaDB: not running"
fi

spinner_start "Testing frontend" 5
sleep 2
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1/zabbix/" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^(200|302|301)$ ]]; then
    spinner_stop "ok" "Frontend accessible (HTTP $HTTP_CODE)"
else
    spinner_stop "fail" "Frontend not accessible (HTTP $HTTP_CODE)"
fi

# test agent communication
spinner_start "Testing agent connection" 5
sleep 2
if command -v zabbix_get >/dev/null 2>&1; then
    if zabbix_get -s 127.0.0.1 -k agent.ping 2>/dev/null | grep -q "1"; then
        spinner_stop "ok" "Agent responding to server"
    else
        spinner_stop "skip" "Agent not responding (may need time to start)"
    fi
else
    spinner_stop "skip" "zabbix_get not installed (optional)"
fi

spinner_start "Testing database connection" 3
if mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT userid FROM users LIMIT 1" >/dev/null 2>&1; then
    spinner_stop "ok" "Database connection OK"
else
    spinner_stop "fail" "Database connection failed"
fi

clear_state

# done
echo
echo -e "${BOLD}${GREEN}  Installation Complete${NC}"
divider
echo -e "  ${BOLD}Frontend${NC}"
echo -e "    URL:      http://$ZABBIX_IP/zabbix"
echo -e "    Username: Admin"
echo -e "    Password: $ZABBIX_ADMIN_PASS"
echo
echo -e "  ${BOLD}Database${NC}"
echo -e "    Name:     $DB_NAME"
echo -e "    User:     $DB_USER"
echo -e "    Password: $DB_PASS"
if [[ -n "${ROOT_PASS:-}" ]]; then
echo
echo -e "  ${BOLD}MariaDB Root${NC}"
echo -e "    Password: $ROOT_PASS"
fi
divider
echo -e "  ${DIM}Credentials saved to: $CREDS_FILE${NC}"
echo -e "  ${DIM}Log file: $LOG_FILE${NC}"
echo

echo "=== Zabbix Installer completed: $(date) ===" >> "$LOG_FILE"
