# Zabbix 7.4 Installer

[![Release](https://img.shields.io/github/v/release/Nix556/Zabbix-Installer?color=blue)](https://github.com/Nix556/Zabbix-Installer/releases)
[![Status](https://img.shields.io/badge/status-working-brightgreen)](https://github.com/Nix556/Zabbix-Installer)
[![Platform](https://img.shields.io/badge/platform-Debian_11/12_|_Ubuntu_22.04/24.04-blue)]()
[![Zabbix](https://img.shields.io/badge/Zabbix-7.4-red)]()
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Interactive scripts to install and uninstall Zabbix 7.4 (Server + Frontend + Agent) on Debian or Ubuntu.

## Supported Systems

- Debian 11 (Bullseye)
- Debian 12 (Bookworm)
- Ubuntu 22.04 (Jammy)
- Ubuntu 24.04 (Noble)

## Features

- Full Zabbix 7.4 stack (server, frontend, agent)
- PHP-FPM with unix sockets
- MariaDB database setup and schema import
- Frontend configuration auto-generated
- Dry-run mode (`--dry-run` or `-n`)
- Resume interrupted installations
- Rollback on failure
- Secure password generation
- Optional backup before uninstall
- Logging to `/var/log/zabbix-installer.log`

## Installation

```bash
git clone https://github.com/Nix556/Zabbix-Installer.git
cd Zabbix-Installer
chmod +x install.sh uninstall.sh
sudo ./install.sh
```

To preview without making changes:

```bash
sudo ./install.sh --dry-run
```

## Configuration

The installer will prompt for:

| Setting | Default |
|---------|---------|
| Server IP | auto-detected |
| Database name | zabbix |
| Database user | zabbix |
| Database password | auto-generated, or enter your own |
| MariaDB root password | auto-generated, or enter your own (`s` for socket auth) |
| Admin password | auto-generated, or enter your own |
| Timezone | system default |

After installation, access the frontend at `http://<SERVER_IP>/zabbix` with username `Admin`.

Credentials are saved to `/root/.zabbix-credentials`.

## Uninstall

```bash
sudo ./uninstall.sh
```

Options during uninstall:
- Backup database and config before removal
- Purge Apache, MariaDB, PHP (optional)
- Remove installer logs (optional)

## Packages Installed

| Component | Packages |
|-----------|----------|
| Zabbix | zabbix-server-mysql, zabbix-frontend-php, zabbix-sql-scripts, zabbix-agent |
| Web | apache2, php-fpm |
| Database | mariadb-server, mariadb-client |
| PHP | php-mysql, php-xml, php-bcmath, php-mbstring, php-ldap, php-gd, php-zip, php-curl |
| Tools | wget, curl, gnupg2, jq, fping, snmpd |

## Troubleshooting

Resume a failed install:
```bash
sudo ./install.sh
# Select "Resume" when prompted
```

Check services:
```bash
systemctl status zabbix-server zabbix-agent apache2 mariadb
```

View logs:
```bash
cat /var/log/zabbix-installer.log
tail -f /var/log/zabbix/zabbix_server.log
```

## License

MIT