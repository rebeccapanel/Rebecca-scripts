# Rebecca Scripts

Rebecca installer scripts have moved to the main Rebecca repository:

https://github.com/rebeccapanel/Rebecca/tree/master/scripts/rebecca

Install Rebecca:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca/master/scripts/rebecca/rebecca.sh)" @ install
```

Install with an explicit mode:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca/master/scripts/rebecca/rebecca.sh)" @ install --mode docker
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca/master/scripts/rebecca/rebecca.sh)" @ install --mode binary
```

Binary release assets are published from the main repository for Linux `amd64`, `arm64`, `armv7`, `ppc64le`, and `s390x`.

Install Rebecca Node:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rebeccapanel/Rebecca/master/scripts/rebecca/rebecca-node.sh)" @ install
```

The entrypoint files in this repository forward to the canonical scripts in `rebeccapanel/Rebecca`.
