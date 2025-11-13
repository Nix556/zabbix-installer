detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS_NAME="Debian"
        OS_VERSION=$(cut -d. -f1 /etc/debian_version)
        PM="apt"
    elif [[ -f /etc/lsb-release ]]; then
        OS_NAME="Ubuntu"
        OS_VERSION=$(lsb_release -rs)
        PM="apt"
    else
        error "Unsupported OS"
        exit 1
    fi
}

update_system() {
    if [[ $EUID -eq 0 ]]; then
        $PM update -y
    else
        sudo $PM update -y
    fi
}
