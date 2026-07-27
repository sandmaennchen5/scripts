# Pangolin Maintenance Tool

A comprehensive maintenance utility for **Pangolin** installations.

The tool provides an interactive menu for managing:

* Updates
* Backups
* Restores
* Container operations
* System diagnostics
* Docker image cleanup

---

## Features

### Update

* Checks Pangolin and Gerbil versions
* Updates Docker image references
* Creates an automatic backup before updating
* Pulls new images
* Restarts the Pangolin stack
* Rolls back when an update fails

### Backup

Creates backups of the Pangolin installation, including:

* `config/`
* `docker-compose.yml`
* `.env`
* `traefik_config.yml`
* `branding/`

Each backup includes a `metadata.json` file containing:

* Creation date
* Script version
* Hostname
* User
* Working directory
* Operating system
* Kernel
* Architecture
* Docker version
* Docker Compose version
* Container versions
* Traefik plugin versions
* Included files
* Checksums
* Backup size
* Backup type

### Restore

The interactive restore menu lists available backups with:

* Backup date
* Pangolin version
* Gerbil version
* Backup size
* Backup type

After selecting a backup, the tool displays detailed information before restoring:

* Host information
* All container versions
* All Traefik plugin versions
* Docker and Docker Compose versions
* Operating system
* Kernel
* Architecture
* Included files
* Backup size

Older backups using the previous metadata format remain supported.

### Container Management

The complete Pangolin Docker Compose stack can be managed directly from the menu.

Available actions:

* Start all containers
* Stop all containers
* Restart all containers
* Display container status
* Display logs for a selected container

### System Diagnostics

The diagnostic function checks:

#### Docker

* Docker daemon availability
* Docker Compose availability
* Docker socket access

#### Containers

* Running containers
* Restarting containers
* Exited containers
* Dead containers
* Missing containers
* Docker health-check status

#### Images

* Missing local images
* Missing image tags
* Compose image availability

#### Configuration

* `docker-compose.yml`
* `traefik_config.yml`
* `.env`
* `config/`

The Compose configuration is validated using:

```bash
docker compose config -q
```

#### Pangolin availability

An optional HTTP or HTTPS test can verify whether Pangolin is reachable.

### System Cleanup

The cleanup function safely detects outdated Docker images related to the current Pangolin installation.

The following images are protected automatically:

* Images currently referenced by `docker-compose.yml`
* Images currently used by existing containers

Additional cleanup functions include:

* Remove outdated Pangolin-related images
* Remove dangling images
* Display Docker disk usage

Every destructive action requires confirmation.

---

## Requirements

The following software is required:

* Linux
* Bash
* Docker Engine
* Docker Compose plugin
* `jq`
* `tar`
* `curl`

Example installation on Debian or Ubuntu:

```bash
sudo apt update
sudo apt install -y jq tar curl
```

Docker must already be installed and running.

Verify Docker:

```bash
docker --version
docker compose version
```

---

## Download

The script is available from:

```text
https://github.com/sandmaennchen5/scripts/blob/main/pangolin/maintenance.sh
```

### Download with curl

Open a terminal and change to your Pangolin installation directory:

```bash
cd /opt/pangolin
```

Download the script from the raw GitHub URL:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/sandmaennchen5/scripts/main/pangolin/maintenance.sh \
  -o maintenance.sh
```

### Download with wget

Alternatively:

```bash
wget \
  https://raw.githubusercontent.com/sandmaennchen5/scripts/main/pangolin/maintenance.sh \
  -O maintenance.sh
```

### Make the script executable

```bash
chmod +x maintenance.sh
```

---

## Installation Directory

The script should normally be stored and executed inside the Pangolin installation directory.

Example:

```text
/opt/pangolin/
├── maintenance.sh
├── docker-compose.yml
├── .env
├── config/
├── branding/
└── traefik_config.yml
```

Change to this directory before running the tool:

```bash
cd /opt/pangolin
```

---

## Usage

Start the interactive maintenance tool:

```bash
sudo ./maintenance.sh
```

The main menu provides access to:

```text
[1] Update
[2] Create backup
[3] Restore backup
[4] Refresh versions
[5] Container management
[6] System diagnostics
[7] System cleanup
[0] Exit
```

Root privileges may be required depending on the Docker installation and permissions.

When the current user has access to Docker without `sudo`, the tool can also be started with:

```bash
./maintenance.sh
```

---

## Container Management

Open the interactive tool:

```bash
sudo ./maintenance.sh
```

Select:

```text
[5] Container management
```

Available actions include:

```text
[1] Start containers
[2] Stop containers
[3] Restart containers
[4] Show status
[5] Show logs
[0] Back
```

### Start from the command line

```bash
sudo ./maintenance.sh --start
```

### Stop from the command line

```bash
sudo ./maintenance.sh --stop
```

### Restart from the command line

```bash
sudo ./maintenance.sh --restart
```

---

## System Diagnostics

Run the diagnostics from the interactive menu:

```text
[6] System diagnostics
```

Or run diagnostics directly:

```bash
sudo ./maintenance.sh --diagnose
```

The diagnostic report checks Docker, Compose, containers, health status, images and configuration files.

---

## Pangolin Availability Test

The Pangolin URL can be supplied through the `PANGOLIN_HEALTH_URL` environment variable.

Example:

```bash
sudo PANGOLIN_HEALTH_URL="https://pangolin.example.com" \
  ./maintenance.sh
```

The URL is then used during system diagnostics.

For a direct diagnostic run:

```bash
sudo PANGOLIN_HEALTH_URL="https://pangolin.example.com" \
  ./maintenance.sh --diagnose
```

---

## Updating the Maintenance Script

To replace the local copy with the latest version from GitHub:

```bash
cd /opt/pangolin
```

Create a backup of the current script:

```bash
cp maintenance.sh maintenance.sh.bak
```

Download the current version:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/sandmaennchen5/scripts/main/pangolin/maintenance.sh \
  -o maintenance.sh
```

Restore executable permissions:

```bash
chmod +x maintenance.sh
```

Check the Bash syntax:

```bash
bash -n maintenance.sh
```

Start the tool:

```bash
sudo ./maintenance.sh
```

---

## One-Line Installation

The script can be downloaded and made executable with:

```bash
cd /opt/pangolin && \
curl -fsSL \
  https://raw.githubusercontent.com/sandmaennchen5/scripts/main/pangolin/maintenance.sh \
  -o maintenance.sh && \
chmod +x maintenance.sh
```

Then run:

```bash
sudo ./maintenance.sh
```

---

## Security Recommendation

Review scripts downloaded from the internet before running them with root privileges.

Display the downloaded script:

```bash
less maintenance.sh
```

Validate its Bash syntax:

```bash
bash -n maintenance.sh
```

Only run the script after verifying that the source and contents are trusted.

Avoid executing remote scripts directly through commands such as:

```bash
curl URL | sudo bash
```

Downloading the file first makes it possible to inspect the script before execution.

---

## Backup Metadata Example

```json
{
  "created": "2026-07-27T20:15:00+02:00",
  "script_version": "2.0",
  "hostname": "pangolin-host",
  "docker_version": "28.3.3",
  "compose_version": "2.39.1",
  "containers": {
    "pangolin": "ee-1.21.0",
    "gerbil": "1.0.0",
    "traefik": "v3.5.1"
  },
  "plugins": {
    "geoblock": "v0.3.6"
  }
}
```

---

## Safety

The tool is designed to operate safely by default.

Safety features include:

* Backup before updates
* Restore safety backup
* Rollback after failed operations
* Confirmation before destructive actions
* Configuration validation
* Compatibility with older backups
* Protection of active Docker images
* Protection of images referenced by Docker Compose

---

## Troubleshooting

### Permission denied

Make sure the script is executable:

```bash
chmod +x maintenance.sh
```

Then run it again:

```bash
sudo ./maintenance.sh
```

### Docker permission denied

Run the tool with `sudo`:

```bash
sudo ./maintenance.sh
```

Alternatively, configure the current user for Docker access according to the Docker documentation.

### Docker daemon unavailable

Check Docker:

```bash
sudo systemctl status docker
```

Start Docker if necessary:

```bash
sudo systemctl start docker
```

### Docker Compose unavailable

Verify the Compose plugin:

```bash
docker compose version
```

### Compose file not found

Make sure the tool is executed from the Pangolin installation directory containing:

```text
docker-compose.yml
```

Example:

```bash
cd /opt/pangolin
sudo ./maintenance.sh
```

### Invalid Compose configuration

Validate the file manually:

```bash
docker compose config -q
```

### Pangolin availability test fails

Verify the configured URL:

```bash
curl -I https://pangolin.example.com
```

Also check DNS, firewall rules, certificates and the Traefik container logs.

---

## Project Goal

The Pangolin Maintenance Tool provides one central interface for:

* Updating Pangolin
* Creating backups
* Restoring installations
* Inspecting component versions
* Managing containers
* Diagnosing problems
* Cleaning obsolete Docker images

This reduces the need for manual Docker and file-management commands.

---

## License

MIT License
