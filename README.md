# Rebecca-scripts
Scripts for Rebecca

## Installing Rebecca
- **Install Rebecca with SQLite**:

```bash
sudo bash -c "$(curl -sL https://github.com/Gozargah/Rebecca-scripts/raw/master/rebecca.sh)" @ install
```

- **Install Rebecca with MySQL**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/Gozargah/Rebecca-scripts/raw/master/rebecca.sh)" @ install --database mysql
  ```

- **Install Rebecca with MariaDB**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/Gozargah/Rebecca-scripts/raw/master/rebecca.sh)" @ install --database mariadb
  ```
  
- **Install Rebecca with MariaDB and Dev branch**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/Gozargah/Rebecca-scripts/raw/master/rebecca.sh)" @ install --database mariadb --dev
  ```

- **Install Rebecca with MariaDB and Manual version**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/Gozargah/Rebecca-scripts/raw/master/rebecca.sh)" @ install --database mariadb --version v0.5.2
  ```

- **Update or Change Xray-core Version**:

  ```bash
  sudo rebecca core-update
  ```


## Installing Rebecca-node
Install Rebecca-node on your server using this command
```bash
sudo bash -c "$(curl -sL https://github.com/Gozargah/Rebecca-scripts/raw/master/rebecca-node.sh)" @ install
```
Install Rebecca-node on your server using this command with custom name:
```bash
sudo bash -c "$(curl -sL https://github.com/Gozargah/Rebecca-scripts/raw/master/rebecca-node.sh)" @ install --name rebecca-node2
```
Or you can only install this script (rebecca-node command) on your server by using this command
```bash
sudo bash -c "$(curl -sL https://github.com/Gozargah/Rebecca-scripts/raw/master/rebecca-node.sh)" @ install-script
```

Use `help` to view all commands:
```rebecca-node help```

- **Update or Change Xray-core Version**:

  ```bash
  sudo rebecca-node core-update
  ```
