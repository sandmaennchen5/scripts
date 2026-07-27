# Pangolin Update Script

A configurable update utility for **Pangolin**, **Traefik plugins**, and **Docker images** with automatic version detection, backups, multilingual support, and unattended execution.

## Features

* Automatically detects available updates for:

  * Docker images
  * Traefik plugins
* Supports **automatic** and **manual** update modes
* Supports update scopes:

  * Patch
  * Minor
  * Major
* Automatically preserves tag variants such as:

  * `ee-*`
  * `postgresql-*`
  * `ee-postgresql-*`
  * `v*`
  * and other custom prefixes
* Optional backup of the `./config` directory before container updates
* Automatic YAML backup before modifications
* Backup retention policy
* Interactive or fully unattended execution
* English and German user interface
* Configurable through environment variables
* Optional Docker Compose update (`pull` + `up -d`)
* Bash syntax checked

---

# Requirements

* Bash
* Docker
* Docker Compose
* Internet connection

---

# Usage

Interactive:

```bash
sudo ./update.sh
```

Show version:

```bash
./update.sh --version
```

---

# Configuration

The script can be configured either by editing the variables at the top of the script or by using environment variables.

## Script Information

```bash
SCRIPT_NAME="Pangolin Update Script"
SCRIPT_VERSION="1.1"
```

---

## Language

```bash
LANGUAGE=de
```

Available values:

* `de`
* `en`

Example:

```bash
LANGUAGE=en ./update.sh
```

---

## Execution

```bash
UNATTENDED=false
```

Values:

* `true`
* `false`

---

## Update Mode

```bash
UPDATE_MODE=ask
```

Values:

* `ask`
* `auto`
* `manual`
* `none`

---

## Update Level

```bash
UPDATE_LEVEL=ask
```

Values:

* `ask`
* `patch`
* `minor`
* `major`

### Patch

Updates only within the same minor version.

Example:

```
1.20.0 → 1.20.5
```

### Minor

Updates only within the same major version.

Example:

```
1.20.0 → 1.24.3
```

### Major

Updates to the newest available version while keeping the tag variant.

Example:

```
1.20.0 → 2.0.1
```

---

# Default Answers

Every interactive question supports a configurable default value.

## Update Mode

```bash
DEFAULT_UPDATE_MODE=none
```

Values:

* `auto`
* `manual`
* `none`

---

## Update Level

```bash
DEFAULT_UPDATE_LEVEL=patch
```

Values:

* `patch`
* `minor`
* `major`

---

## Docker Compose

```bash
DEFAULT_RUN_COMPOSE=yes
```

Values:

* `yes`
* `no`

---

## Config Backup

```bash
DEFAULT_CONFIG_BACKUP=yes
```

Values:

* `yes`
* `no`

---

## Manual Selection

```bash
DEFAULT_MANUAL_SELECTION=0
```

Values:

* `0` = Skip update
* `1` = Select first available version
* `2` = Select second available version
* ...

Pressing **Enter** automatically selects the configured default.

---

# Docker Compose

```bash
RUN_COMPOSE=ask
```

Values:

* `ask`
* `yes`
* `no`

---

# Config Backup

```bash
CONFIG_BACKUP=ask
```

Values:

* `ask`
* `yes`
* `no`

---

# Backup Retention

```bash
BACKUP_RETENTION_DAYS=30
BACKUP_MIN_KEEP=3
```

The script automatically removes old backups while always keeping the newest backups.

---

# Output Modes

## Debug

```bash
DEBUG=true
```

Displays additional information such as:

* detected tags
* selected versions
* configuration
* filtering decisions

---

## Quiet

```bash
QUIET=true
```

Suppresses normal informational output while still displaying warnings and errors.

---

# Backup Structure

```
backups/
├── config/
│   ├── config-2026-07-27_120000.tar.gz
│   └── ...
└── yaml/
    ├── docker-compose-2026-07-27_120000.yml
    └── ...
```

---

# Automatic Examples

## Fully automatic patch update

```bash
sudo env \
LANGUAGE=en \
UNATTENDED=true \
UPDATE_MODE=auto \
UPDATE_LEVEL=patch \
CONFIG_BACKUP=yes \
RUN_COMPOSE=yes \
./update.sh
```

---

## Automatic minor updates

```bash
sudo env \
UNATTENDED=true \
UPDATE_MODE=auto \
UPDATE_LEVEL=minor \
RUN_COMPOSE=yes \
CONFIG_BACKUP=yes \
./update.sh
```

---

## Automatic major updates

```bash
sudo env \
UNATTENDED=true \
UPDATE_MODE=auto \
UPDATE_LEVEL=major \
RUN_COMPOSE=yes \
CONFIG_BACKUP=yes \
./update.sh
```

---

## Check for updates only

```bash
sudo env \
UNATTENDED=true \
UPDATE_MODE=none \
RUN_COMPOSE=no \
./update.sh
```

---

# Version Detection

The script automatically detects version prefixes and preserves them during updates.

Examples:

```
1.20.0
ee-1.20.0
postgresql-1.20.0
ee-postgresql-1.20.0
v3.7.8
```

Only matching variants are considered during update selection.

---

# Exit Codes

| Code | Meaning                     |
| ---: | --------------------------- |
|    0 | Success                     |
|    1 | General error               |
|    2 | Invalid configuration       |
|    3 | Required dependency missing |

---

# License

This project is provided as-is without warranty.

Feel free to modify and distribute it according to your project's license.
