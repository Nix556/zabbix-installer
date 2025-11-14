# Zabbix Installer (v7.4)

[![Development Status](https://img.shields.io/badge/status-in_development-yellow)](https://github.com/Nix556/Zabbix-Installer)
[![Platform](https://img.shields.io/badge/platform-Debian_12_|_Ubuntu_22.04-blue)]()
[![Zabbix Version](https://img.shields.io/badge/Zabbix-7.4-orange)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()

> **Note:** This project is still in development and may not work perfectly yet.

---

## Overview

This repository provides **interactive Bash scripts** to install, configure, and uninstall **Zabbix 7.4** (Server + Frontend + Agent) on **Debian 12** or **Ubuntu 22.04**.  
It also includes a `zabbix_api.sh` script for managing hosts through the **Zabbix API**.

Everything is automated repository setup, MariaDB configuration, Apache/PHP setup, and frontend generation.

---

## Project Structure

```
zabbix-installer/
├─ install.sh             # Full interactive installer (Debian 12 / Ubuntu 22.04)
├─ uninstall.sh           # Clean uninstaller (removes all Zabbix components)

```

---

## Installation Steps

### 1. Prepare System

Clone the repo and enter the directory:

```bash
git clone https://github.com/Nix556/Zabbix-Installer.git
cd Zabbix-Installer
```

Make sure scripts are executable:

```bash
chmod +x install.sh uninstall.sh zabbix_api.sh
chmod +x lib/*.sh
```

---

### 2. Run the Installer

Run interactively:

```bash
sudo ./install.sh
```

The script will ask for:

- MariaDB root password  
- Zabbix database name, user, and password  
- Zabbix server IP  
- Zabbix frontend admin password  

It automatically installs:

- Zabbix server, frontend, and agent  
- MariaDB and Apache + PHP  
- Repository and schema setup  
- Config files + frontend credentials  

At the end, it shows:

```
Frontend URL: http://<ZABBIX_IP>/zabbix
Admin user: Admin
Admin password: <your-password>
```

---

## Uninstallation

Remove Zabbix completely:

```bash
sudo ./uninstall.sh
```

Removes:

- Zabbix server, agent, and frontend  
- MariaDB (optional cleanup)  
- Apache + PHP configs  
- `/etc/zabbix/` and `/var/log/zabbix/`  
- Drops Zabbix DB and user  

The script automatically detects credentials from `/etc/zabbix/zabbix_server.conf`.

---

## Notes

- Supported OS: Debian 12 and Ubuntu 22.04  
- Zabbix version: 7.4 (latest)  
- PHP timezone: Auto-detected and configured  
- Schema: Imported automatically  
- API config: Stored in `config/zabbix_api.conf`  
- Privileges: Requires root or sudo  
- Status: Tested in development environments only  

---

## License

This project is licensed under the MIT License.  
See the [LICENSE](LICENSE) file for details.
