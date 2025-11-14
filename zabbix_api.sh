#!/bin/bash
# Zabbix API management tool

set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="config/zabbix_api.conf"
LIB_DIR="lib"

source "$LIB_DIR/colors.sh"
source "$LIB_DIR/utils.sh"

# check API config
[[ ! -f $CONFIG_FILE ]] && { error "API config not found! Run install.sh first."; exit 1; }
source "$CONFIG_FILE"

# API login function
login_api() {
    local response token
    response=$(curl -s -X POST -H 'Content-Type: application/json-rpc' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"user\":\"$ZABBIX_USER\",\"password\":\"$ZABBIX_PASS\"},\"id\":1}" \
        "$ZABBIX_URL/api_jsonrpc.php")
    token=$(echo "$response" | jq -r '.result')
    [[ "$token" == "null" || -z "$token" ]] && { error "API login failed. Check credentials."; exit 1; }
    echo "$token"
}

API_TOKEN=$(login_api)

# spinner wrapper
show_spinner() {
    local pid=$1
    local msg=$2
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
    echo -e "\b[OK] $msg"
}

# List hosts
list_hosts() {
    curl -s -X POST -H 'Content-Type: application/json-rpc' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"output\":[\"hostid\",\"host\",\"name\"]},\"auth\":\"$API_TOKEN\",\"id\":2}" \
        "$ZABBIX_URL/api_jsonrpc.php" | jq
}

# Prompt for interfaces interactively
prompt_interfaces() {
    local interfaces ip port arr idx=0 json
    interfaces="[]"
    while true; do
        read -rp "Enter interface IP (or blank to finish): " ip
        [[ -z "$ip" ]] && break
        validate_ip "$ip" || { warn "Invalid IP"; continue; }
        read -rp "Enter port [10050]: " port
        port=${port:-10050}
        validate_port "$port" || { warn "Invalid port"; continue; }
        # append interface to JSON array
        json="{\"type\":1,\"main\":1,\"useip\":1,\"ip\":\"$ip\",\"dns\":\"\",\"port\":\"$port\"}"
        if [[ $idx -eq 0 ]]; then
            interfaces="[$json]"
        else
            interfaces=$(echo "$interfaces" | jq ". + [$json]")
        fi
        idx=$((idx+1))
    done
    echo "$interfaces"
}

# Prompt templates interactively
prompt_templates() {
    local templates template json idx=0
    templates="[]"
    while true; do
        read -rp "Enter template ID (or blank to finish): " template
        [[ -z "$template" ]] && break
        [[ "$template" =~ ^[0-9]+$ ]] || { warn "Template ID must be numeric"; continue; }
        json="{\"templateid\":$template}"
        if [[ $idx -eq 0 ]]; then
            templates="[$json]"
        else
            templates=$(echo "$templates" | jq ". + [$json]")
        fi
        idx=$((idx+1))
    done
    echo "$templates"
}

# Add host function
add_host() {
    local host_name visible_name group_id interfaces templates confirm_msg
    # check CLI arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --host-name) host_name="$2"; shift 2 ;;
            --visible-name) visible_name="$2"; shift 2 ;;
            --group-id) group_id="$2"; shift 2 ;;
            --interface) interfaces="$2"; shift 2 ;;
            --template) templates="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # interactive prompts if missing
    [[ -z "$host_name" ]] && read -rp "Enter host name: " host_name
    [[ -z "$visible_name" ]] && read -rp "Enter visible name (default: host name): " visible_name
    visible_name=${visible_name:-$host_name}
    [[ -z "$group_id" ]] && read -rp "Enter group ID (default: 2): " group_id
    group_id=${group_id:-2}

    [[ -z "$interfaces" ]] && interfaces=$(prompt_interfaces)
    [[ -z "$templates" ]] && templates=$(prompt_templates)

    # confirmation summary
    echo -e "${BLUE}Ready to add host with the following configuration:${NC}"
    echo -e "${YELLOW}Host Name:${NC} $host_name"
    echo -e "${YELLOW}Visible Name:${NC} $visible_name"
    echo -e "${YELLOW}Group ID:${NC} $group_id"
    echo -e "${YELLOW}Interfaces:${NC} $interfaces"
    echo -e "${YELLOW}Templates:${NC} $templates"

    confirm "Proceed?" || { warn "Cancelled"; exit 0; }

    # API call
    curl -s -X POST -H 'Content-Type: application/json-rpc' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.create\",\"params\":{\"host\":\"$host_name\",\"name\":\"$visible_name\",\"groups\":[{\"groupid\":$group_id}],\"interfaces\":$interfaces,\"templates\":$templates},\"auth\":\"$API_TOKEN\",\"id\":3}" \
        "$ZABBIX_URL/api_jsonrpc.php" &
    show_spinner $! "Adding host $host_name..."
}

# Remove host function
remove_host() {
    local host_id host_name
    if [[ $# -gt 0 ]]; then
        host_name="$1"
    else
        read -rp "Enter host name to remove: " host_name
    fi
    # find host ID
    host_id=$(curl -s -X POST -H 'Content-Type: application/json-rpc' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"filter\":{\"host\":[\"$host_name\"]},\"output\":[\"hostid\"]},\"auth\":\"$API_TOKEN\",\"id\":4}" \
        "$ZABBIX_URL/api_jsonrpc.php" | jq -r '.result[0].hostid')
    [[ -z "$host_id" || "$host_id" == "null" ]] && { error "Host not found"; exit 1; }

    echo -e "${BLUE}Host to remove:${NC} $host_name (ID: $host_id)"
    confirm "Proceed?" || { warn "Cancelled"; exit 0; }

    curl -s -X POST -H 'Content-Type: application/json-rpc' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.delete\",\"params\":[\"$host_id\"],\"auth\":\"$API_TOKEN\",\"id\":5}" \
        "$ZABBIX_URL/api_jsonrpc.php" &
    show_spinner $! "Removing host $host_name..."
}

# CLI dispatch
case "$1" in
    list-hosts) list_hosts ;;
    add-host) shift; add_host "$@" ;;
    remove-host) shift; remove_host "$@" ;;
    *) echo "Usage: $0 {list-hosts|add-host|remove-host}" ;;
esac
