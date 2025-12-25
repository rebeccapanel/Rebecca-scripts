# Rebecca-scripts
Scripts for Rebecca

## Installing Rebecca
- **Install Rebecca with SQLite**:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install
````

* **Install Rebecca with MySQL**:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install --database mysql
```

* **Install Rebecca with MariaDB**:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install --database mariadb
```

* **Install Rebecca with MariaDB and Dev branch**:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install --database mariadb --dev
```

* **Install Rebecca with MariaDB and Manual version**:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install --database mariadb --version v0.5.2
```

* **Update or Change Xray-core Version**:

```bash
sudo rebecca core-update
```

## Installing Rebecca-node

Install Rebecca-node on your server using this command:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh)" @ install
```

Install Rebecca-node on your server with a custom name:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh)" @ install --name rebecca-node2
```

Or you can only install this script (`rebecca-node` command) on your server by using this command:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh)" @ install-script
```

Use `help` to view all commands:

```bash
rebecca-node help
```

* **Update or Change Xray-core Version**:

```bash
sudo rebecca-node core-update
```

## V2bX helper scripts

Quick install and management scripts for a standalone V2bX node (upstream sources for now; update URLs later when we host our fork).

* Install V2bX:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/v2bx/v2bx_install.sh)"
```

* Menu / management helper (start/stop/restart/update/config generator/logs):

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/v2bx/v2bx_manage.sh)"
```

The systemd unit file used by the installer is in `v2bx/v2bx.service`.

## Maintenance service only

Need only the maintenance API (systemd unit that exposes update/backup endpoints) without reinstalling the full stack? Run:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca.sh)" @ install-service
```

This command fetches `main.py` together with the new `maintenance_requirements.txt`, installs the required Python packages (FastAPI, Uvicorn, PyYAML, etc.) using pip with `--break-system-packages` when necessary, and enables `rebecca-maint.service`.

### Node maintenance service only

For standalone nodes you can also install just the Rebecca-node maintenance API (used by the dashboard for updates/telemetry) without touching the compose stack:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/rebecca-node.sh)" @ install-service --name rebecca-node
```

Replace `--name` with your node CLI name if you installed multiple instances (e.g. `--name ali-node`). The node script downloads its FastAPI app plus `requirements.txt`, installs dependencies with `pip --break-system-packages`, and enables `<node-name>-maint.service`. When `--name` is omitted the installer now scans `/opt/*/docker-compose.yml`, prints all detected nodes, and lets you pick the target.

## Migration scripts

If you are migrating from Marzban you can reuse your data using the dedicated scripts stored in **Rebecca-scripts**:

* **Panel migration (Marzban → Rebecca)**

  ```bash
  sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/migrate_marzban_to_rebecca.sh)"
  ```

  The script renames databases (while MySQL/MariaDB containers are still running), rewrites compose/env values, installs the maintenance service and keeps your existing domain paths.

* **Node migration (Marzban node → Rebecca-node)**

  ```bash
  sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca-scripts/master/migrate_marzban_node_to_rebecca.sh)"
  ```

  This utility discovers every node compose file under `/opt`, allows you to pick a target (or pass `--name <node-name>`), updates the volumes/image to `rebeccapanel/rebecca-node`, keeps the directory name (e.g. `/opt/v2ray`), and installs a node-specific CLI/maintenance service so you can run commands like `v2ray up`.

> **Tip:** Always back up your compose files and databases before running any migration script.
