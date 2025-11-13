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

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        for i in $(echo $ip | tr '.' ' '); do
            (( i >= 0 && i <= 255 )) || return 1
        done
        return 0
    else
        return 1
    fi
}

show_spinner() {
    local pid=$1
    local msg=$2
    local end_msg=$3
    local delay=0.1
    local spinstr='|/-\'
    echo -n "$msg "
    while kill -0 $pid 2>/dev/null; do
        for i in $(seq 0 3); do
            printf "\b${spinstr:$i:1}"
            sleep $delay
        done
    done
    wait $pid
    echo -e "\b[OK] $end_msg"
}
