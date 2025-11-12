# Zabbix Installer

This repository contains scripts to install, configure, and uninstall Zabbix server and agent on Debian 12. It also includes a script to manage hosts via the Zabbix API.

---

## 1. Clone or Create the Repository

If you already have all the files saved locally:

```bash
mkdir ~/zabbix-installer
cd ~/zabbix-installer
```

Ensure the directory structure matches:

```
zabbix-installer/
├─ install.sh
├─ uninstall.sh
├─ zabbix_api.sh
├─ lib/
│   ├─ colors.sh
│   ├─ utils.sh
│   ├─ system.sh
│   └─ db.sh
└─ config/
```

If you are using the GitHub version:

```bash
git clone <YOUR_GITHUB_REPO_URL> zabbix-installer
cd zabbix-installer
```

---

## 2. Make Scripts Executable

```bash
chmod +x install.sh uninstall.sh zabbix_api.sh
chmod +x lib/*.sh
```

---

## 3. Run the Installer

```bash
sudo ./install.sh
```

You will be presented with a menu:

* **Full Zabbix Server + Agent**
* **Zabbix Agent only**
* **Exit**

Select `1` to install the full server, MariaDB, Apache + PHP, and the agent.

---

## 4. Follow the Installation

The script will ask for:

* MariaDB root password
* Type of installation

Everything else will be installed automatically:

* MariaDB database and user for Zabbix
* Apache + PHP
* Zabbix server and agent
* Zabbix API cache configuration

---

## 5. Run Zabbix API Scripts

After installation, you can add, list, or remove hosts:

```bash
sudo ./zabbix_api.sh
```

The menu will ask you what action you want to perform:

* **Add Host**
* **List Hosts**
* **Remove Host**
* **Exit**

You can modify the URL, username, and password if you haven't cached a token yet.

---

## 6. Uninstallation

To remove everything:

```bash
sudo ./uninstall.sh
```

This will remove:

* Zabbix server
* Zabbix agent
* MariaDB
* Apache + PHP
* All configuration files
