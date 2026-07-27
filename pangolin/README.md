# Pangolin Maintenance Tool

> **Version 2.4**

A comprehensive Bash utility for maintaining and diagnosing self-hosted **Pangolin** installations.

It provides one interactive tool for updates, backups, restores, container operations, diagnostics, cleanup, configuration migration, and safe self-updates.

## What's New in 2.4

- Host firewall detection and port-rule checks
  - UFW
  - firewalld
  - nftables
  - iptables
- Dynamic firewall validation for detected Pangolin ports
- Optional TCP reachability checks
- `.env` is treated as optional during diagnostics
- `443/udp` is recognized as the optional Pangolin HTTP/3 / QUIC port
- `443/udp` is excluded from Raw Resource consistency checks
- Clear separation between errors, warnings, and informational UDP limitations
- Updated self-update URL and configuration migration

## Features

### Updates

- Checks available Pangolin and Gerbil versions
- Supports automatic, manual, and filtered version selection
- Creates a backup before applying updates
- Updates Docker image references
- Pulls the selected images
- Restarts the Pangolin stack
- Reverts unapplied changes when requested
- Supports unattended operation through `maintenance.conf`

### Backup

Backups can include:

- `config/`
- `docker-compose.yml`
- optional `.env`
- Traefik configuration
- branding files

Each backup contains a `metadata.json` file with information such as:

- Creation date
- Script version
- Hostname and user
- Working directory
- Operating system, kernel, and architecture
- Docker and Docker Compose versions
- Container images and versions
- Traefik plugins
- Included files and checksums
- Backup size and type

### Restore

The interactive restore menu displays:

- Backup date
- Pangolin version
- Gerbil version
- Backup size
- Backup type

Before restoring, the tool can show detailed metadata including host information, container versions, plugins, system data, included files, and backup information.

Older backup metadata formats remain supported.

### Container Management

The complete Docker Compose stack can be managed from the menu or CLI:

- Start containers
- Stop containers
- Restart containers
- Show status
- Show logs

### System Diagnostics

The diagnostic module checks the following areas.

#### Docker

- Docker daemon availability
- Docker Compose availability
- Docker socket access
- Compose configuration validity

#### Containers and Images

- Container state
- Restarting, exited, dead, or missing containers
- Docker health-check status
- Container uptime
- Missing local images or tags

#### Configuration

- `docker-compose.yml`
- `config/`
- Traefik configuration
- optional `.env`

A missing `.env` is reported as informational and is not counted as an error.

#### Dashboard

The dashboard URL is detected from:

```yaml
app:
  dashboard_url:
```

in `config/config.yml`.

The tool then performs HTTP and HTTPS reachability checks where possible.

#### Pangolin Ports

Tunnel ports are read dynamically from `config/config.yml`:

```yaml
gerbil:
  start_port:
  clients_start_port:
```

Traefik entry points are read from:

```text
config/traefik/traefik_config.yml
```

Docker Compose short and long port syntax are supported, including explicit host-to-container mappings and protocols.

The standard checks cover:

- `80/tcp` — non-SSL resources
- `443/tcp` — SSL resources
- configured site-tunnel UDP port
- configured client-tunnel UDP port
- `443/udp` — optional HTTP/3 / QUIC, when published

For every published port, the tool checks the Docker mapping and local host listener.

#### HTTP/3 / QUIC

Pangolin's installation Compose may publish:

```yaml
- 443:443/udp # For http3 QUIC if desired
```

The tool therefore treats `443/udp` as an optional Pangolin system port. It is not classified as a Raw Resource port and its absence is not an error.

#### Host Firewall

The tool detects an active host firewall in this order:

1. UFW
2. firewalld
3. nftables
4. iptables

When an active firewall is detected, the tool checks rules for:

- `80/tcp`
- `443/tcp`
- detected site-tunnel UDP port
- detected client-tunnel UDP port
- optional `443/udp`, when published

Results are classified as allowed, blocked/not allowed, or not reliably determinable.

If no active host firewall is detected, the result is informational rather than an error.

#### TCP and UDP Reachability

When enabled, the script performs a TCP connection test from the Pangolin host to the detected dashboard hostname and published TCP ports.

This test is useful, but depending on DNS, NAT, and provider routing it may not fully reproduce a connection from an unrelated external client.

For UDP, the tool reports:

> External UDP connectivity cannot be verified automatically.

and, where relevant:

> External cloud/provider firewalls cannot be verified automatically for UDP.

UDP has no TCP-style connection handshake. A conclusive inbound test requires a remote peer, client, or test service.

#### Raw Resource Consistency

Additional Gerbil ports are compared with Traefik entry points.

The following Pangolin system ports are excluded from Raw Resource checks:

- configured site-tunnel UDP port
- configured client-tunnel UDP port
- `80/tcp`
- `443/tcp`
- `443/udp`

#### Diagnostic Summary

The report ends with separate totals:

```text
Errors: 0
Warnings: 0
```

Informational limitations, optional files, and disabled optional features do not count as errors.

### System Cleanup

The cleanup module can:

- Remove outdated, unused Compose images
- Remove dangling images
- Display Docker disk usage

The tool protects:

- Images referenced by the active Compose configuration
- Images used by existing containers
- Matching image IDs, even when tags differ

Destructive actions require confirmation.

## Configuration

On first start, the script automatically creates:

```text
maintenance.conf
```

On later starts it:

- Preserves user-defined values
- Adds new configuration options automatically
- Refreshes comments and descriptions
- Creates `maintenance.conf.bak` before replacing the generated configuration

Important networking options introduced for version 2.4:

```bash
ENABLE_EXTERNAL_TCP_TEST=true
TCP_TEST_TIMEOUT=5
```

Disable the TCP check with:

```bash
ENABLE_EXTERNAL_TCP_TEST=false
```

The script self-update settings are:

```bash
SCRIPT_UPDATE_MODE=ask
SCRIPT_UPDATE_URL=https://raw.githubusercontent.com/sandmaennchen5/scripts/refs/heads/main/pangolin/maintenance.sh
SCRIPT_UPDATE_TIMEOUT=8
```

Allowed update modes:

- `ask`
- `auto`
- `off`

## Requirements

- Linux
- Bash
- Docker Engine
- Docker Compose plugin
- `curl`
- `jq`
- `yq`
- `tar`

Optional firewall commands are used when installed:

- `ufw`
- `firewall-cmd`
- `nft`
- `iptables`

Example for Debian or Ubuntu:

```bash
sudo apt update
sudo apt install -y curl jq yq tar
```

Docker must already be installed and running.

## Download

Change to the Pangolin installation directory:

```bash
cd /opt/pangolin
```

Download the current script:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/sandmaennchen5/scripts/refs/heads/main/pangolin/maintenance.sh \
  -o maintenance.sh
```

Make it executable:

```bash
chmod +x maintenance.sh
```

Validate the Bash syntax before running it:

```bash
bash -n maintenance.sh
```

Start the tool:

```bash
sudo ./maintenance.sh
```

## Interactive Menu

```text
[1] Update
[2] Create backup
[3] Restore backup
[4] Check versions again
[5] Container management
[6] System diagnostics
[7] System cleanup
[8] Check for script update
[0] Exit
```

## Command-Line Usage

```text
--backup
--restore [backup]
--check
--diagnose
--start
--stop
--restart
--self-update
--version
-V
```

Examples:

```bash
sudo ./maintenance.sh --diagnose
sudo ./maintenance.sh --backup
sudo ./maintenance.sh --start
sudo ./maintenance.sh --stop
sudo ./maintenance.sh --restart
sudo ./maintenance.sh --self-update
./maintenance.sh --version
```

## Updating the Maintenance Script

Use the menu entry:

```text
[8] Check for script update
```

or run:

```bash
sudo ./maintenance.sh --self-update
```

The update process:

1. Downloads the remote script
2. Reads and compares `SCRIPT_VERSION`
3. Validates it with `bash -n`
4. Creates a backup of the current script
5. Replaces the script atomically
6. Restarts the updated script when appropriate

The persistent `maintenance.conf` is not replaced by a script update.

## Installation Directory

A typical installation looks like:

```text
/opt/pangolin/
├── maintenance.sh
├── maintenance.conf
├── docker-compose.yml
├── config/
├── branding/
└── backups/
```

The optional `.env` file may also be present.

## Safety

Safety features include:

- Automatic backup before updates
- Pre-restore safety backup
- Rollback after failed operations
- Confirmation before destructive actions
- Compose and Bash validation
- Backward-compatible restore handling
- Protection of active Docker images
- Persistent configuration separated from the script

Review scripts downloaded from the internet before running them with root privileges. Download the file first instead of piping a remote URL directly into `sudo bash`.

## Troubleshooting

### Permission denied

```bash
chmod +x maintenance.sh
sudo ./maintenance.sh
```

### Docker permission denied

Run the tool with `sudo`, or configure the current user for Docker access.

### Docker daemon unavailable

```bash
sudo systemctl status docker
sudo systemctl start docker
```

### Invalid Compose configuration

```bash
docker compose config -q
```

### Firewall result is unknown

The tool intentionally reports an informational result when a firewall rule cannot be interpreted reliably. Complex nftables sets, custom chains, interfaces, source filters, Docker-managed rules, or provider firewalls may require manual inspection.

### UDP appears locally open but clients cannot connect

Check:

- Docker publishes the correct UDP port
- A local listener exists
- The host firewall permits the port
- The cloud/provider firewall permits the port
- DNS points to the correct public address
- A real remote Pangolin client or peer can reach the server

## License

MIT License
