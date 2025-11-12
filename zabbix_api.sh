#!/bin/bash
CONFIG_FILE="config/zabbix_api.conf"
source lib/colors.sh

if [[ ! -f $CONFIG_FILE ]]; then
    error "Config file not found. Copy and edit config/zabbix_api.conf"
    exit 1
fi

source "$CONFIG_FILE"

API_JSON='{"jsonrpc":"2.0","method":"user.login","params":{"user":"'"$ZABBIX_USER"'","password":"'"$ZABBIX_PASS"'"},"id":1}'

AUTH_TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' -d "$API_JSON" "$ZABBIX_URL/api_jsonrpc.php" | jq -r '.result')

if [[ -z "$1" ]]; then
    echo "Usage: $0 [list|add|remove] args..."
    exit 1
fi

ACTION="$1"; shift

case "$ACTION" in
    list)
        curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"host.get","params":{"output":["hostid","host","status"]},"auth":"'"$AUTH_TOKEN"'","id":1}' "$ZABBIX_URL/api_jsonrpc.php" | jq
        ;;
    add)
        HOSTNAME="$1"
        IP="$2"
        curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"host.create","params":{"host":"'"$HOSTNAME"'","interfaces":[{"type":1,"main":1,"useip":1,"ip":"'"$IP"'","dns":"","port":"10050"}],"groups":[{"groupid":"2"}]},"auth":"'"$AUTH_TOKEN"'","id":1}' "$ZABBIX_URL/api_jsonrpc.php" | jq
        ;;
    remove)
        HOSTID="$1"
        curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"host.delete","params":["'"$HOSTID"'"],"auth":"'"$AUTH_TOKEN"'","id":1}' "$ZABBIX_URL/api_jsonrpc.php" | jq
        ;;
    *)
        error "Unknown action"
        ;;
esac
