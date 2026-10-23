# Synology Database Stack — PostgreSQL + MariaDB + Valkey

## Overview

Centralized 3-container stack for Synology Container Manager / Docker Compose.

- PostgreSQL: `paperless` (user `paperlessuser`), `forgejo` (user `forgejo`)
- MariaDB: `romm` (user `romm`), `game` (user `gameuser`)
- Valkey: shared service for Paperless and RomM. **One global password, not app isolation.**
- Private external Docker network: `database-net`
- No host-exposed SQL/cache ports; containers reachable only from attached Docker networks.
- Manager creates additional databases, app logins, passwords and backs up/restores data.

**Compatibility:** The image tags are version-family starting points, not compatibility guarantees. Verify tag availability (`docker compose pull`) and application support before upgrading. Never auto-update database major versions.

## 1. Copy to Synology

Copy the project folder to `/volume1/docker/stack_database/` (preserve hidden `.env.example`). SSH in:

```bash
cd /volume1/docker/stack_database
chmod 700 scripts/*.sh
chmod 644 postgres/init/*.sh mariadb/init/*.sh
./scripts/setup.sh
# Make encrypted/offsite backup of .env NOW.
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
./scripts/db-manager.sh list all
```

`setup.sh` creates `.env` once with 7 different random passwords. Permissions: `.env` 600, credentials and backups 700. Make sure the Synology ACLs permit Docker to write the DB data folders; do not `chmod 777`. MariaDB and PostgreSQL initialization scripts run **only when their data directories are empty**. Run on a newly initialized stack first and verify backups *before* migrating existing data.

## 2. Passwords

`.env` defines distinct administrator passwords:
- `POSTGRES_ADMIN_PASSWORD` (database admin `postgres`)
- `MARIADB_ROOT_PASSWORD` (admin `root`)
- `VALKEY_PASSWORD` (one shared cache authentication password)

Application database passwords are also separately configurable on *first initialization*. On an already initialized database, changing `.env` alone **does not rotate passwords**. Use `db-manager.sh rotate ENGINE NAME` for *manager-created* app users. This changes the database user and managed credentials file, but you must update the consuming app credentials and restart its service. For initial seeded users (`paperlessuser`, `forgejo`, `romm`, `gameuser`), use SQL `ALTER ROLE` / `ALTER USER` with appropriately updated app config. Administrator and Valkey password rotations require controlled maintenance and updating the relevant authentication configuration; no unsupported automatic admin rotation is implied.

**Security model:** Docker administrators can inspect container env variables; protect NAS administrators and Docker socket. This starter package stores passwords in `.env` and per-app `credentials/*.env` (not Docker secrets). Do not commit them to Git or send them to third parties. If the NAS has many admins/users, move to Docker secrets and least-privilege ACL design.

## 3. Manager

```bash
./scripts/db-manager.sh                       # interactive menu
./scripts/db-manager.sh status
./scripts/db-manager.sh list all
./scripts/db-manager.sh create postgres myapp
./scripts/db-manager.sh create mariadb anotherapp
./scripts/db-manager.sh rotate postgres myapp
./scripts/db-manager.sh backup all
./scripts/db-manager.sh backup postgres paperless
./scripts/db-manager.sh backup mariadb romm
./scripts/db-manager.sh backup valkey
./scripts/db-manager.sh restore postgres myapp /volume1/docker/stack_database/backups/postgres/myapp_DATE.dump
./scripts/db-manager.sh restore mariadb anotherapp /volume1/docker/stack_database/backups/mariadb/anotherapp_DATE.sql.gz
./scripts/db-manager.sh restore-valkey /volume1/docker/stack_database/backups/valkey/all_DATE.tar.gz
```

Name restrictions: `[a-z][a-z0-9_]{0,30}`. `create` aborts if a DB or user exists. Generated 64-hex passwords are saved to `credentials/<app>-<engine>.env` with chmod 600. A rare interruption during creation could leave a partial database/user; do not rerun blindly, inspect and clean up manually.

**Restore safety:** SQL restore is only supported into an **existing EMPTY target database**, for a single-database backup, with explicit confirmation. It will reject a nonempty target. For an application with complex ownership, ensure the target is owned by the correct app user. All-instance SQL backups (`backup all`) are **disaster-recovery archives**, restored only to fresh compatible servers using documented PostgreSQL and MariaDB procedures, not by this interactive restore command. Do not pipe them into active instances. Each restore should be rehearsed on an isolated test stack.

**Valkey restore** needs all client applications stopped. It stops Valkey, archives the old `data/` directory, installs the backup, restarts Valkey. Restoration may roll back queues/jobs. It never overwrites the old copy without keeping it, but needs enough free disk space.

## 4. Backups

- SQL per database: `pg_dump -Fc` / `mariadb-dump`.
- All SQL data: `pg_dumpall` (roles included) / `mariadb-dump --all-databases` (includes internal metadata).
- Valkey: **brief outage** while copying persisted AOF/RDB data. AOF `appendfsync everysec` is configured, but test crash consistency.
- Backups go under `backups/<engine>/`; the manager adds SHA-256 checksums.
- **No automatic pruning**: configure retention in Synology Hyper Backup, or add and test a controlled retention job. The backup set also needs offsite/second-NAS copies; local backups are not disaster recovery.
- App files are NOT included. Independently backup Paperless documents, Forgejo repos, RomM ROM library, game saves, application config and `.env`/credentials. Encrypt credential backups.
- For Synology Task Scheduler run as a Docker-authorized user or root:

```bash
/bin/bash /volume1/docker/stack_database/scripts/db-manager.sh backup all
```

Schedule once nightly during low usage. Verify backup artifacts, test restores, and alert on non-zero exit. MariaDB `--single-transaction` is consistent for InnoDB with no concurrent DDL; simultaneous cross-engine consistency is not guaranteed. Avoid changing schemas while dumps run.

## 5. Application connectivity

Attach **each application's actual service** to the shared network:

```yaml
services:
  app:
    networks: [default, database-net]
networks:
  database-net:
    external: true
    name: database-net
```

Use:

| App | Host:port | Database | User |
| --- | --- | --- | --- |
| Paperless | `database-postgres:5432` | `paperless` | `paperlessuser` |
| Forgejo | `database-postgres:5432` | `forgejo` | `forgejo` |
| RomM | `database-mariadb:3306` | `romm` | `romm` |
| Games | `database-mariadb:3306` | `game` | `gameuser` |
| Paperless Valkey | `database-valkey:6379` | Redis-compatible URL | shared password |
| RomM Valkey | `database-valkey:6379` | Redis-compatible client | shared password |

Paperless: `PAPERLESS_REDIS=redis://:<VALKEY_PASSWORD>@database-valkey:6379/0` and `PAPERLESS_DBHOST=database-postgres`. The `REDIS` name in Paperless's environment variable does not imply running Redis. RomM's Valkey environment variable spelling is release-dependent; check the release docs (commonly `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWD`). A *shared* Valkey means one app could affect another app's keys or queues; separate Valkey containers or tested ACL/key-prefix isolation are preferable for strict independence.

The central `.env` is not magically inherited by the other Compose projects: transfer the appropriate password to each app's protected `.env` or secret configuration.

## 6. Migrating old containers

1. Record old DB engine/major versions; back up source databases and app files while in a consistent state.
2. Never mount existing PostgreSQL 14 data folders into PostgreSQL 18 directly. **Use compatible logical dump/restore or supported upgrade processes.** Likewise for MariaDB major upgrades.
3. Stop the old app while taking final snapshots, initialize this new stack on **empty** directories, and migrate one app at a time into its own new database.
4. Test login and actual application data before removing old containers. The pre-created databases are empty; first-time application startup is fine, existing-app migration requires restoration.
5. A changed Valkey host is not necessarily a seamless move of pending queues/jobs. Stop clients and follow application migration guidance.

## 7. Disaster recovery notes

Full PostgreSQL backup: restore a `pg_dumpall` SQL file on a fresh compatible PostgreSQL instance with `psql -X -v ON_ERROR_STOP=1` after testing user/role conflicts. Full MariaDB backup: restore on fresh same-major MariaDB to avoid system table conflicts; for different majors, use more targeted logical migration. Valkey data archive may contain secrets and must be encrypted at rest/offsite.

**Not included:** Web UI, direct NAS access, live production restore guarantees, automatic administrator password rotation, auto updates. Configure Synology firewall, offsite backups, UPS, disk monitoring, and change control independently.

## Menü-Erweiterung: Restore-Auswahl und Überschreiben

`./scripts/db-manager.sh` bietet nummerierte Auswahl von SQL-Datenbanken und datierten Einzelbackups. Das neueste Backup steht an erster Stelle und ist standardmäßig ausgewählt (Enter). Beim Restore kannst du zwischen *nur leere Datenbank* und *bestehende Datenbank überschreiben* wählen. Überschreiben erfordert das wörtliche Bestätigen von `OVERWRITE postgres NAME` bzw. `OVERWRITE mariadb NAME` und erzeugt **zwingend vorher ein Sicherheitsbackup**. Halte vorher die betroffene Anwendung an; laufende Verbindungen und gleichzeitig schreibende Anwendungen können Daten inkonsistent machen. Nach Abbruch oder Fehler muss die Sicherung gegebenenfalls manuell wiederhergestellt werden. Der Restore ist keine automatische Transaktion.

CLI: `./scripts/db-manager.sh restore postgres paperless /volume1/docker/stack_database/backups/postgres/paperless_YYYYMMDD_HHMMSS.dump overwrite`. Ohne letztes Argument (`safe`) ist nur ein leeres Ziel erlaubt. Menüpunkt 8 ermöglicht Restore eines Valkey-Backups nach Auswahl; Valkey kann nicht pro Anwendung getrennt wiederhergestellt werden.

Einzelbackups eignen sich für den interaktiven Restore. Vollständige SQL-Backups (`all_*.sql.gz`) dienen der kompletten Wiederherstellung auf einem separaten, frischen Datenbankserver und werden **nicht** als Einzel-Datenbank-Restore angeboten. Passwortrotation gilt nur für vom Manager angelegte Konten mit gespeicherten Credentials; Administratorpasswörter werden dabei nicht geändert.

**Nicht implementiert:** interaktive Löschung von Datenbanken/Benutzern und Valkey-ACL-Benutzerverwaltung. Das ist bewusst nicht durch ungetestete destruktive Menüpunkte ersetzt worden.
