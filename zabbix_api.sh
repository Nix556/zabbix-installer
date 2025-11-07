#!/bin/bash
source lib/colors.sh
source lib/utils.sh

CONFIG_FILE="config/zabbix_api.conf"

loadToken() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
}

saveToken() {
    echo "ZBX_TOKEN=$ZBX_TOKEN" >"$CONFIG_FILE"
}

getToken() {
    loadToken
    if [[ -z "$ZBX_TOKEN" ]]; then
        read -rp "Zabbix URL: " ZBX_URL
        read -rp "Zabbix User: " ZBX_USER
        read -rsp "Zabbix Password: " ZBX_PASS
        echo
        ZBX_TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' -d \
        "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"user\":\"$ZBX_USER\",\"password\":\"$ZBX_PASS\"},\"id\":1}" "$ZBX_URL" | jq -r '.result')
        saveToken
    fi
}

addHost() {
    getToken
    read -rp "Host name: " HOSTNAME
    read -rp "Host IP: " HOSTIP
    curl -s -X POST -H 'Content-Type: application/json' -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"host.create\",\"params\":{\"host\":\"$HOSTNAME\",\"interfaces\":[{\"type\":1,\"main\":1,\"useip\":1,\"ip\":\"$HOSTIP\",\"dns\":\"\",\"port\":\"10050\"}]},\"auth\":\"$ZBX_TOKEN\",\"id\":1}" "$ZBX_URL"
    echo -e "${GREEN}Host added.${NC}"
}

listHosts() {
    getToken
    curl -s -X POST -H 'Content-Type: application/json' -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"output\":[\"hostid\",\"host\"]},\"auth\":\"$ZBX_TOKEN\",\"id\":1}" "$ZBX_URL" | jq -r '.result[] | "\(.hostid) \(.host)"'
}

removeHost() {
    getToken
    listHosts
    read -rp "Enter HostID to remove: " HOSTID
    curl -s -X POST -H 'Content-Type: application/json' -d \
    "{\"jsonrpc\":\"2.0\",\"method\":\"host.delete\",\"params\":[\"$HOSTID\"],\"auth\":\"$ZBX_TOKEN\",\"id\":1}" "$ZBX_URL"
    echo -e "${GREEN}Host removed.${NC}"
}

echo "1) Add Host"
echo "2) List Hosts"
echo "3) Remove Host"
echo "4) Exit"
read -rp "Choice [1-4]: " API_CHOICE
case "$API_CHOICE" in
1) addHost ;;
2) listHosts ;;
3) removeHost ;;
4) exit 0 ;;
*) echo -e "${RED}Invalid choice${NC}" ;;
esac
