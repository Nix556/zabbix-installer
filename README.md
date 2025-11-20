# Zabbix Installer 7.4

[![Development Status](https://img.shields.io/badge/status-in_development-yellow)](https://github.com/Nix556/Zabbix-Installer)  
[![Platform](https://img.shields.io/badge/platform-Debian_12_|_Ubuntu_22.04-blue)]()  
[![Zabbix Version](https://img.shields.io/badge/Zabbix-7.4-orange)]()  
[![License](https://img.shields.io/badge/license-MIT-green)]()

A small collection of interactive Bash scripts to install and uninstall Zabbix 7.4 (Server + Frontend + Agent)
on Debian 12 or Ubuntu 22.04. The installer automates repository setup, MariaDB creation, and Apache+PHP-FPM wiring.

Highlights
- Installs Zabbix 7.4 server, frontend and agent
- Uses PHP-FPM (avoids mod_php) and configures Apache to proxy PHP via unix socket
- Creates database, user and imports schema automatically
- Creates frontend config (/etc/zabbix/web/zabbix.conf.php) and sets recommended PHP options
- Provides an uninstall script that removes packages, files and (optionally) the supporting stack

Repository layout
```
zabbix-installer/
├─ install.sh             # Interactive installer (Debian 12 / Ubuntu 22.04)
├─ uninstall.sh           # Uninstaller (optionally purges Apache/MariaDB/PHP)
├─ README.md
```

Quick start
1. Clone and enter the directory:
```bash
git clone https://github.com/Nix556/Zabbix-Installer.git
cd Zabbix-Installer
chmod +x install.sh uninstall.sh
```

2. Run the installer:
```bash
sudo ./install.sh
```
The script prompts for:
- Zabbix Server IP (used for agent Server/ServerActive)
- Zabbix DB name, user and password
- MariaDB root password (leave empty if using socket auth)
- Frontend Admin password

At the end the script prints the frontend URL and Admin credentials:
```
Access frontend at: http://<ZABBIX_IP>/zabbix
Username: Admin
Password: <your-password>
```

Notes and troubleshooting
- The installer prefers PHP-FPM and sets Apache to proxy PHP via `/run/php/php<version>-fpm.sock`.
- The installer uses apt with "no recommends" to avoid pulling libapache2-mod-php by default.
- If you see "Forbidden" on the UI, check:
  - Apache conf /etc/apache2/conf-available/zabbix.conf has Directory set to `/usr/share/zabbix` (unquoted).
  - Permissions: `chown -R root:root /usr/share/zabbix && find /usr/share/zabbix -type d -exec chmod 755 {} \;`
  - `systemctl status apache2` and `journalctl -u apache2 -n 200`
- If MariaDB schema import fails, verify that MySQL socket is up and credentials are correct:
  - `systemctl status mariadb`
  - `mysql -uroot -p -e "SHOW DATABASES;"`

License
- MIT

Contributions and issues
- Open issues and PRs at the repository. Small improvements welcome.
