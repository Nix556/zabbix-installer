ask() { 
    local prompt=$1
    local default=$2
    read -rp "$prompt [$default]: " answer
    echo "${answer:-$default}"
}

confirm() {
    read -rp "$1 [y/N]: " ans
    [[ $ans =~ ^[Yy]$ ]]
}
