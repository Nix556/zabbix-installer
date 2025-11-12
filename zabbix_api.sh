#!/bin/bash
CONFIG_FILE="config/zabbix_api.conf"
if [[ ! -f $CONFIG_FILE ]]; then
    echo "API config not found! Run install.sh first."
    exit 1
fi
source "$CONFIG_FILE"

API_LOGIN=$(curl -s -X POST -H 'Content-Type: application/json-rpc' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"user\":\"$ZABBIX_USER\",\"password\":\"$ZABBIX_PASS\"},\"id\":1}" \
    "$ZABBIX_URL/api_jsonrpc.php" | jq -r '.result')

if [[ "$1" == "list-hosts" ]]; then
    curl -s -X POST -H 'Content-Type: application/json-rpc' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"output\":[\"hostid\",\"host\"]},\"auth\":\"$API_LOGIN\",\"id\":2}" \
        "$ZABBIX_URL/api_jsonrpc.php" | jq
else
    echo "Usage: $0 list-hosts"
fi
