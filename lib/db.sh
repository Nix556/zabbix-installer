setupMariaDB() {
    read -rp "MariaDB root password: " DB_ROOT
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT'; FLUSH PRIVILEGES;"
    mysql -e "CREATE DATABASE zabbix character set utf8mb4 collate utf8mb4_bin;"
    mysql -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY 'zabbix';"
    mysql -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost'; FLUSH PRIVILEGES;"
}
installZabbixServer() { apt-get install -y zabbix-server-mysql zabbix-frontend-php; systemctl enable zabbix-server; systemctl start zabbix-server; }
installZabbixAgent() { apt-get install -y zabbix-agent; systemctl enable zabbix-agent; systemctl start zabbix-agent; }
configureZabbixAPI() { touch config/zabbix_api.conf; }
