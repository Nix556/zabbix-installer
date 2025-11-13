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

Everything is automated — repository setup, MariaDB configuration, Apache/PHP setup, and frontend generation.

---

## Quick Start Example

Install and configure Zabbix 7.4 interactively, then manage hosts via the API:

```bash
# Make scripts executable
chmod +x install.sh uninstall.sh zabbix_api.sh
chmod +x lib/*.sh

# Run installer (interactive)
sudo ./install.sh

# Add a host via API (example)
sudo ./zabbix_api.sh add-host   --host-name "web01"   --visible-name "Web Server 01"   --group-id 2   --interface '[{"type":1,"main":1,"useip":1,"ip":"192.168.1.10","dns":"","port":"10050"}]'   --template '[{"templateid":10001}]'
```

---

## Project Structure

```
zabbix-installer/
├─ install.sh             # Full interactive installer (Debian 12 / Ubuntu 22.04)
├─ uninstall.sh           # Clean uninstaller (removes all Zabbix components)
├─ zabbix_api.sh          # Manage Zabbix hosts via API
├─ lib/
│   ├─ colors.sh          # Common color variables
│   ├─ utils.sh           # Helper functions
│   ├─ system.sh          # Service controls
│   └─ db.sh              # Database management helpers
└─ config/
    └─ zabbix_api.conf    # Generated automatically after installation
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

## Zabbix API Script

The `zabbix_api.sh` tool works both interactively and via CLI automation.

### Example Commands

List hosts:

```bash
sudo ./zabbix_api.sh list-hosts
```

Add a host with templates:

```bash
sudo ./zabbix_api.sh add-host   --host-name "web01"   --visible-name "Web Server 01"   --group-id 2   --interface '[{"type":1,"main":1,"useip":1,"ip":"192.168.1.10","dns":"","port":"10050"}]'   --template '[{"templateid":10001},{"templateid":10002}]'
```

| Argument | Description |
|-----------|-------------|
| `--host-name` | Required host name |
| `--visible-name` | Optional, defaults to host name |
| `--group-id` | Host group ID (default: `2` = Linux servers) |
| `--interface` | JSON array of interfaces (IP + port) |
| `--template` | JSON array of template IDs |

Remove a host:

```bash
sudo ./zabbix_api.sh remove-host
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
