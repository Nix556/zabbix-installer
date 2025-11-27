# Zabbix Installer 7.4

[![Status](https://img.shields.io/badge/status-working-brightgreen)](https://github.com/Nix556/Zabbix-Installer)
[![Development](https://img.shields.io/badge/development-active-blue)](https://github.com/Nix556/Zabbix-Installer)
[![Platform](https://img.shields.io/badge/platform-Debian_12_|_Ubuntu_22.04-lightgrey)]()
[![Zabbix Version](https://img.shields.io/badge/Zabbix-7.4-red)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()

Fully automated interactive Bash scripts to **install** and **uninstall** Zabbix 7.4 (Server + Frontend + Agent) on Debian 12 or Ubuntu 22.04. Handles repository setup, MariaDB database creation, Apache + PHP-FPM configuration, and all required PHP settings automatically.

---

## Features

- **Full Zabbix 7.4 stack** — Server, Frontend, and Agent
- **PHP-FPM** — Modern setup using unix sockets (no mod_php)
- **Automated database setup** — Creates database, user, and imports schema
- **Frontend configuration** — Auto-generates `/etc/zabbix/web/zabbix.conf.php`
- **PHP tuning** — Sets required values (post_max_size, max_execution_time, etc.)
- **Clean uninstall** — Removes everything including database, with option to purge full stack
- **Reinstall-friendly** — Handles broken packages and leftover files from previous installations

---

## Repository Structure

```
Zabbix-Installer/
├── install.sh      # Interactive installer
├── uninstall.sh    # Complete uninstaller  
├── README.md
└── LICENSE
```

---

## Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/Nix556/Zabbix-Installer.git
cd Zabbix-Installer

# Make scripts executable
chmod +x install.sh uninstall.sh

# Run installer as root
sudo ./install.sh
```

The installer will prompt for:
| Prompt | Default | Description |
|--------|---------|-------------|
| Zabbix Server IP | `127.0.0.1` | Used for agent configuration |
| Zabbix DB name | `zabbix` | MariaDB database name |
| Zabbix DB user | `zabbix` | MariaDB username |
| Zabbix DB password | *(required)* | MariaDB user password |
| MariaDB root password | *(empty)* | Leave empty for socket auth |
| Frontend Admin password | `zabbix` | Zabbix web UI password |

After completion:
```
Access frontend at: http://<ZABBIX_IP>/zabbix
Username: Admin
Password: <your-password>
```

### Uninstallation

```bash
sudo ./uninstall.sh
```

The uninstaller will:
1. Drop the Zabbix database and user
2. Remove all Zabbix packages and configuration
3. Remove the Zabbix repository
4. *(Optional)* Purge the entire auxiliary stack (Apache, MariaDB, PHP, tools)

---

## What Gets Installed

| Component | Packages |
|-----------|----------|
| **Zabbix** | zabbix-server-mysql, zabbix-frontend-php, zabbix-sql-scripts, zabbix-agent |
| **Web Server** | apache2, php-fpm |
| **Database** | mariadb-server, mariadb-client |
| **PHP Modules** | php-mysql, php-xml, php-bcmath, php-mbstring, php-ldap, php-gd, php-zip, php-curl |
| **Tools** | wget, curl, gnupg2, jq, fping, snmpd |

---

## Troubleshooting

<details>
<summary><strong>Zabbix server not running</strong></summary>

```bash
systemctl status zabbix-server
journalctl -u zabbix-server -n 50
```
Check database connectivity and `/etc/zabbix/zabbix_server.conf` settings.
</details>

<details>
<summary><strong>"Forbidden" error on web UI</strong></summary>

```bash
# Check Apache configuration
apachectl configtest

# Verify permissions
chown -R root:root /usr/share/zabbix
find /usr/share/zabbix -type d -exec chmod 755 {} \;
find /usr/share/zabbix -type f -exec chmod 644 {} \;

# Restart services
systemctl restart apache2 php8.2-fpm
```
</details>

<details>
<summary><strong>Database connection issues</strong></summary>

```bash
# Check MariaDB status
systemctl status mariadb

# Test connection
mysql -uzabbix -p -e "SELECT 1;"

# Verify socket exists
ls -la /run/mysqld/mysqld.sock
```
</details>

<details>
<summary><strong>PHP requirements not met</strong></summary>

The installer configures PHP automatically, but if needed:
```bash
# Edit PHP-FPM config
nano /etc/php/8.2/fpm/php.ini

# Set these values:
# post_max_size = 16M
# max_execution_time = 300
# max_input_time = 300

# Restart PHP-FPM
systemctl restart php8.2-fpm
```
</details>

---

## Roadmap

- [ ] **UI improvements** — Progress spinners and cleaner output
- [ ] **API automation** — Script to configure Zabbix via API (hosts, templates, etc.)
- [ ] **Additional OS support** — Rocky Linux, AlmaLinux
- [ ] **Backup script** — Export database and configuration
- [ ] **Update script** — In-place Zabbix upgrades

---

## License

[MIT License](LICENSE) — Free to use, modify, and distribute.

---

## Contributing

Contributions welcome! Feel free to:
- Open issues for bugs or feature requests
- Submit pull requests for improvements
- Share feedback and suggestions

---

*Made by [Nix556](https://github.com/Nix556)*