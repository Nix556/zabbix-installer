#!/bin/bash

detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
        VER=$(cut -d'.' -f1 /etc/debian_version)
        PM="apt"
    else
        error "Unsupported OS"
        exit 1
    fi
    info "Detected OS: $OS $VER"
}

update_system() {
    info "Updating system packages..."
    sudo $PM update -y && sudo $PM upgrade -y
}
