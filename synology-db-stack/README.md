# Synology Database Manager – Zentrale und externe Datenbank-Backups

Diese Anleitung beschreibt zwei **separate Bash-Skripte** für eine Synology NAS:

1. **`db-manager.sh`** (bei Installation als `db-manager.sh`): Verwaltung der zentralen Docker-Dienste **`database-postgres`**, **`database-mariadb`** und **`database-valkey`** inklusive Erstellung, Backup, Restore und eingeschränkter Löschfunktion.
2. **`db-export.sh`**: Sicherung von **MariaDB/MySQL** und **PostgreSQL** aus anderen Docker-Containern oder über **TCP/IP** von anderen Rechnern. Dieses Skript **sichert**, stellt aber selbst keine Datenbanken wieder her.

> **Wichtig:** Die Anleitung basiert auf den bereitgestellten Skriptversionen. Ein Live-Test auf deiner NAS und ein vollständiger Test-Restore wurden nicht durchgeführt. Vor produktiver Nutzung mit einer Testdatenbank prüfen.

## 1. Voraussetzungen

- Synology NAS mit SSH, Bash, Docker/Container Manager und Zugriff auf die relevanten Container.
- Für den zentralen Manager: laufende Container `database-postgres`, `database-mariadb`, `database-valkey`, passende Datenbankprogramme darin, `gzip`, `tar`, `sha256sum`, `openssl` und eine `.env` im **aktuellen Arbeitsverzeichnis** mit `MARIADB_ROOT_PASSWORD`, `POSTGRES_ADMIN_PASSWORD` und `VALKEY_PASSWORD`. Die zentrale PostgreSQL-Anbindung erwartet den Linux- und SQL-Benutzer `postgres`.
- Für PostgreSQL: `pg-tools.sh` neben beide Skripte kopieren. Docker muss laufen und fehlende offizielle `postgres:<Hauptversion>`-Images herunterladen können. Lokale PostgreSQL-Binaries werden für externe Verbindungen und Restore nicht benötigt. Für MariaDB/MySQL zusätzlich `my-tools.sh` neben beide Skripte kopieren. Externe Verbindungen und der zentrale Restore verwenden ebenfalls temporäre Werkzeug-Container.
- Für TCP: Netzwerkzugriff, richtiger Port, erlaubte Benutzeranmeldung, ausreichende Leserechte für Daten und Dump von Routinen/Triggern/Events (sofern verwendet). **Datenbankports nicht ungeschützt ins Internet freigeben**; VPN/privates Netz und TLS, sofern sinnvoll, bevorzugen.

## 2. Installation

Skripte in `/volume1/docker/stack_database/` kopieren. Vor Ersetzen einer bestehenden Version ein Backup anlegen:

```bash
cd /volume1/docker/stack_database
cp -p db-manager.sh db-manager.sh.vor-update.bak   # falls vorhanden
chmod 700 db-manager.sh db-export.sh
bash -n db-manager.sh
bash -n db-export.sh
```

Den zentralen Manager **aus diesem Verzeichnis starten**, da er `.env` relativ zum aktuellen Verzeichnis lädt:

```bash
cd /volume1/docker/stack_database
./db-manager.sh
```

Den externen Backup-Manager starten:

```bash
cd /volume1/docker/stack_database
./db-export.sh
```

Der externe Manager kann alternativ durch `DB_MANAGER_BASE=/anderer/pfad` seinen Basisordner wechseln. **Dann liegen die Backups nicht automatisch im Verzeichnis, das der zentrale Restore-Manager durchsucht.**

## 3. Zentraler `db-manager.sh` – Menü

| Punkt | Funktion |
|---|---|
| 1 | Status der `database-*`-Container |
| 2 | Datenbanken von PostgreSQL und MariaDB sowie belegte Valkey-Datenbanken auflisten |
| 3 | Anwendungsdatenbank **plus gleichnamigen Benutzer** anlegen, Zugangsdaten speichern |
| 4 | Gesamtsicherung aller drei Dienste (`postgres`, `mariadb`, `valkey`) |
| 5 | Einzel-Backup einer ausgewählten SQL-Datenbank oder Valkey-Snapshot |
| 6 | Einzelne PostgreSQL-/MariaDB-Datenbank aus Backup wiederherstellen |
| 7 | Passwort des verwalteten Datenbankbenutzers erneuern |
| 8 | Valkey aus Snapshot wiederherstellen |
| 9 | Backup-Dateien anzeigen |
| 10 | **Verwaltete** Datenbank plus gleichnamigen Benutzer nach Sicherungsbackup löschen |
| 11 | **Alle Anwendungsdatenbanken einzeln** sichern und zusätzlich Valkey-Snapshot erstellen |
| 0 | Beenden |

**Punkt 4 vs. 11:** Punkt 4 erzeugt einen dienstweiten Gesamtdump für PostgreSQL und MariaDB und einen Valkey-Snapshot. Punkt 11 erzeugt hingegen pro Anwendungsdatenbank einen getrennten Dump, der über Menüpunkt 6 auswählbar ist; Valkey wird weiterhin als gesamter Snapshot gesichert.

Zusätzliche Kommandozeilenbeispiele:

```bash
./db-manager.sh status
./db-manager.sh list all
./db-manager.sh backup all
./db-manager.sh backup postgres meineapp
./db-manager.sh backup-each
./db-manager.sh restore postgres meineapp /volume1/docker/stack_database/backups/postgres/meineapp_YYYYMMDD_HHMMSS.dump safe
```

Die Restore-Option `overwrite` ersetzt vorhandene Daten **destruktiv**; nur nach genauer Prüfung verwenden. Der Manager fordert einen exakten Bestätigungstext an und erstellt davor ein Sicherheitsbackup. **Anwendungen vor Restore und Löschung stoppen.**

### Löschfunktion (Punkt 10)

Nur für Datenbanken mit passender Zugangsdaten-Datei unter `credentials/`; Datenbank und Benutzer müssen denselben Namen haben. Vor dem Löschen erzeugt das Skript einen geprüften Einzel-Dump und archiviert anschließend die Zugangsdaten unter `credentials/deleted/`. Bestehende Backups bleiben erhalten. Eine PostgreSQL-Rolle kann nicht gelöscht werden, wenn weitere Abhängigkeiten bestehen; der Vorgang kann teilweise erfolgreich sein (Datenbank gelöscht, Rolle bleibt bestehen).

## 4. Externer Manager – Profile und Sicherungen

Menü:

| Punkt | Funktion |
|---|---|
| 1 | Verbindungsprofil anlegen (Docker oder TCP/IP) |
| 2 | Gespeichertes Profil auswählen und Verbindung testen |
| 3 | Datenbank auswählen oder **alle gelisteten Anwendungsdatenbanken** einzeln sichern |
| 4 | Backups anzeigen |
| 0 | Beenden |

Beim Anlegen eines Profils werden folgende Angaben abgefragt:

- Profilname (z. B. `homeserver`)
- Verbindungstyp: **Docker-Container** oder **TCP/IP**
- Typ: **MariaDB/MySQL** oder **PostgreSQL**
- Docker-Containername bzw. IP/Hostname
- Port (Standard 3306 oder 5432), SQL-Benutzer, **Wartungsdatenbank** und Passwort

Bei Docker-Verbindungen verwendet das Skript **TCP `127.0.0.1` innerhalb des Containers**, nicht einen Unix-Socket. Das funktioniert nur, wenn der Datenbankserver darin auf der gewählten Adresse und dem Port lauscht. Der Datenbankbenutzer kann frei gewählt werden; es wird **nicht** pauschal `postgres` vorausgesetzt.

Gespeicherte Profile liegen unter:

```text
/volume1/docker/stack_database/external-db-profiles/
  homeserver.conf      # Host, Port, Benutzer usw.
  homeserver.secret    # Passwort im Klartext
```

Dateirechte: Profilverzeichnis `700`, Dateien `600`. **Passwörter werden nicht verschlüsselt.** Verzeichnis nicht in frei lesbare Freigaben oder öffentliche Git-Repositories kopieren. Das derzeitige Skript bietet **kein Menü zum Ändern/Löschen** von Profilen; hierfür Dateien nach Prüfung manuell verwalten.

## 5. Backup-Ablage und Restore-Kompatibilität

Beide Manager legen die SQL-Einzelbackups standardmäßig unter `/volume1/docker/stack_database/backups/` ab:

```text
backups/
├── postgres/
│   ├── meineapp_20261025_180000.dump
│   └── all_20261025_180000.sql.gz
├── mariadb/
│   ├── wordpress_20261025_180000.sql.gz
│   └── all_20261025_180000.sql.gz
└── valkey/
    └── all_20261025_180000.tar.gz
```

- **PostgreSQL-Einzeldump:** `pg_dump -Fc` (`.dump`); Restore mit `pg_restore` über Menüpunkt 6.
- **MariaDB/MySQL-Einzeldump:** SQL ohne `CREATE DATABASE`/`USE` (`.sql.gz`); Import erfolgt in die **vorher ausgewählte Ziel-DB** über Menüpunkt 6.
- **Valkey:** Dateisystem-Snapshot (`.tar.gz`), Restore nur über Menüpunkt 8.
- Ergänzende Dateien: `.sha256`-Prüfsummen; externe Sicherungen zusätzlich `.source.txt` mit Herkunftsangaben. Der zentrale Restore-Dialog listet die eigentlichen Dump-Dateien.

**Für den Restore muss die Zieldatenbank bereits existieren.** Ihr Name muss zum Sicherungsnamen passen. Der zentrale Restore-Manager unterstützt nur Datenbanknamen gemäß `^[a-z][a-z0-9_]{0,30}$`. SQL-Backups von außen können aufgrund von Quell-/Zielversionsunterschieden, Erweiterungen, Collations, Berechtigungen oder Datenbankobjekten trotzdem inkompatibel sein.

**Wichtig bei Namensgleichheit:** Beide Skripte speichern Backups gleicher Datenbanknamen im **selben** Engine-Ordner. Die zusätzliche `.source.txt` kennzeichnet die Herkunft externer Sicherungen, wird aber im Restore-Auswahlmenü **nicht angezeigt**. Deshalb vor einem Restore die Herkunft kontrollieren. Identische Namen plus gleiche sekundengenaue Zeitstempel können kollidieren.

Der zentrale Manager erstellt Gesamtsicherungen mit `all_...`, aber sein SQL-Restore-Menü unterstützt **nur einzelne Datenbanken**, keine komplette `all_`-Wiederherstellung.

## 6. Sicheren Restore durchführen

1. Datenbanktyp, **Zieldatenbank und Quelle** eindeutig zuordnen; `.source.txt` und Prüfsumme gegebenenfalls prüfen.
2. Apps/Clients stoppen, die diese Datenbank benutzen.
3. Ziel-Datenbank bei Bedarf über Menüpunkt 3 anlegen. Für externe Dumps den Ziel-Benutzer und erforderliche Rechte prüfen.
4. Zentralen Manager starten und **6) SQL-Restore** auswählen.
5. Datenbank und Backup-Nummer wählen.
6. `1` für Restore **nur in leere DB** oder `2` für **bestehende DB überschreiben**.
7. Bei Überschreiben exakten Text eingeben, beispielsweise `OVERWRITE mariadb meineapp` (nicht nur `OVERWRITE`).
8. Nach Restore Daten, Berechtigungen und App-Funktion prüfen; erst dann Clients wieder starten.

**Achtung:** Die `safe`-Option schützt nur vor dem Einspielen in eine nichtleere DB, nicht vor jedem inkompatiblen oder schadhaften Dump. Ein verifiziertes Backup sollte mindestens einmal in einer **separaten Testumgebung** erfolgreich wiederhergestellt werden.

## 7. Backup-Dateien prüfen

```bash
# gzip-Integrität (MariaDB)
gzip -t /volume1/docker/stack_database/backups/mariadb/meineapp_YYYYMMDD_HHMMSS.sql.gz

# SHA-256-Datei prüfen
cd /volume1/docker/stack_database/backups/mariadb
sha256sum -c meineapp_YYYYMMDD_HHMMSS.sql.gz.sha256

# PostgreSQL-Archiv prüfen (benötigt pg_restore)
pg_restore -l /volume1/docker/stack_database/backups/postgres/meineapp_YYYYMMDD_HHMMSS.dump
```

`gzip -t`, eine Prüfsumme oder `pg_restore -l` beweisen **keine** vollständige erfolgreiche Datenwiederherstellung.

## 8. Fehlerbehebung

| Meldung / Problem | Erklärung / Maßnahme |
|---|---|
| `FATAL: role "postgres" does not exist` | Bei externen Quellen im Profil den **tatsächlichen SQL-Benutzer** eintragen. Der zentrale Manager setzt für seinen festgelegten PostgreSQL-Container weiterhin `postgres` voraus. |
| `connection refused` | IP, Port, Firewall, Docker-Port-Konfiguration und `listen_addresses` bzw. Bind-Adresse prüfen. |
| `password authentication failed` | Benutzer, Passwort und Server-Authentifizierung prüfen. |
| `No application databases` | Es wurden keine sichtbaren Anwendungsdatenbanken gefunden oder die Abfrage schlug fehl. Rechte und Verbindung testen. |
| `Canceled` nach `OVERWRITE` | Die ganze verlangte Zeichenfolge eingeben, z. B. `OVERWRITE mariadb backup`. |
| `mariadb-dump: command not found` / `pg_dump: command not found` | Geeignete Clientprogramme im NAS-System (TCP) bzw. Container (Docker) bereitstellen. |
| Externer Dump nicht im Restore-Menü | Backup-Pfad, Datenbanknamen, Dateiendung und passenden Engine-Ordner prüfen; `DB_MANAGER_BASE` darf nicht abweichen. |
| PostgreSQL-Restore schlägt fehl | Versionen/Erweiterungen/Rollen/Rechte/Ziel-DB und Fehlermeldung von `pg_restore` prüfen. |

## 9. Wichtige Grenzen und Sicherheit

- Der zentrale Manager arbeitet auf festen lokalen Containern. Der externe Manager dient dem **Backup**, nicht dem Management/Löschen entfernter Datenbanken.
- Beim externen Manager sind Profile und Passwörter lokal auf der NAS gespeichert. `docker exec -e` bzw. `env` geben Geheimnisse an Child-Prozesse weiter; Nutzer mit Administrator-/Docker-Zugriff können diese potenziell sehen.
- `--single-transaction` bei MariaDB schützt nicht zuverlässig bei gleichzeitig laufenden Schemaänderungen und garantiert bei nichttransaktionalen Tabellen nicht dieselbe Konsistenz.
- Weder die Datenbank-Dumps noch Valkey-Snapshots ersetzen eine versionierte, räumlich getrennte Offsite-Sicherung. Backups regelmäßig automatisiert prüfen und mindestens einen Test-Restore durchführen.
- **Menüpunkt 10, Restore mit `overwrite` und Valkey-Restore sind destruktiv.** Vorher Sicherung und Stillstand der betroffenen Anwendungen sicherstellen.

---

**Stand:** 25.10.2026 · Dokumentiert für `db-manager.sh` und `db-export.sh` aus dieser Unterhaltung.

## Automatische PostgreSQL-Werkzeuge

`db-export.sh` ermittelt die Server-Hauptversion mit `psql` aus `postgres:18` und sichert mit `pg_dump` aus dem passenden Image (z. B. `postgres:15` für Veeam 15.18). Die Werkzeugversion steht zusätzlich in `.source.txt`. Der zentrale Manager sichert weiterhin mit den passenden Werkzeugen im eigenen Datenbankcontainer.

`db-manager.sh` liest vor einem Restore die im Archiv gespeicherte pg_dump-Version und verwendet das entsprechende `pg_restore`. Ein älteres Restore-Ziel wird vor Sicherheitsbackup und Überschreiben abgelehnt. Auch bestehende Dumps ohne Metadaten werden geprüft. Diese Prüfung ersetzt keinen Test-Restore; Erweiterungen und andere Versionsunterschiede können weiterhin relevant sein.

Die Werkzeug-Container werden nach jedem Aufruf entfernt; heruntergeladene Images bleiben für weitere Aufrufe verfügbar. TCP-Verbindungen verwenden das Host-Netzwerk der NAS, Docker-Verbindungen den Netzwerk-Namespace des gewählten Containers. Es werden keine Datenverzeichnisse eingebunden und keine zusätzlichen Datenbankserver gestartet. Für die initiale Versionsabfrage/Archivprüfung lässt sich `PG_BOOTSTRAP_MAJOR` setzen (Standard `18`). PostgreSQL ab Hauptversion 10 wird unterstützt.

Beim Update **alle vier Dateien** `db-export.sh`, `db-manager.sh`, `pg-tools.sh` und `my-tools.sh` nach `/volume1/docker/stack_database/` kopieren. Danach:

```bash
cd /volume1/docker/stack_database
bash -n pg-tools.sh && bash -n db-export.sh && bash -n db-manager.sh
./db-export.sh
```

## Automatische MariaDB/MySQL-Werkzeuge

`my-tools.sh` wird von beiden Managern benötigt. Externe Verbindungstests, Datenbanklisten und Backups nutzen kurzlebige Container, sowohl bei TCP/IP als auch bei Docker-Quellen. Eine Abfrage von `VERSION()` und `@@version_comment` mit `mariadb:11.8` erkennt MariaDB oder MySQL und wählt anschließend `mariadb:<major.minor>` bzw. `mysql:<major.minor>`. Das Bootstrap-Image lässt sich mit `MARIADB_BOOTSTRAP_IMAGE` anpassen. Fehlende Images lädt Docker automatisch; ist ein Tag für die NAS-Architektur nicht verfügbar, schlägt der Vorgang fehl.

Dumps verwenden `mariadb-dump` bzw. `mysqldump`. MySQL-Dumps deaktivieren GTID-Übernahme und Tablespace-Dumps; ab MySQL 8 zusätzlich Column Statistics. Das Werkzeug-Image wird in `.source.txt` gespeichert. Der zentrale MariaDB-Restore verwendet den zum Zielserver passenden temporären Client; zentrale Backups bleiben bei den Tools im laufenden Container. Ein Wechsel zwischen MySQL und MariaDB oder zu älteren Servern garantiert keine SQL-Kompatibilität.

Die Container starten nur das Werkzeug und werden anschließend entfernt. TCP verwendet das Host-Netzwerk, Docker den Netzwerk-Namespace der Quelle bzw. des Ziels. Lokale MariaDB-Programme auf DSM sind dafür nicht nötig. Images bleiben im Docker-Cache.

### Restore privilegierter PostgreSQL-Objekte

Für Erweiterungen und C-Funktionen wird eine eindeutige temporäre PostgreSQL-Rolle mit `NOLOGIN SUPERUSER` angelegt. Der komplette Import erfolgt unter dieser Rolle in einer Transaktion. Danach werden ausschließlich deren Objekte an den Ziel-Datenbankbesitzer übertragen und die temporäre Rolle entfernt. Die Anwendungsrolle erhält keine Superuser-Rechte. Bei Importfehlern wird die Transaktion zurückgerollt und die temporäre Rolle bereinigt; scheitert die Bereinigung, meldet das Skript den Rollennamen. Nur vertrauenswürdige Dumps importieren: deren SQL wird mit Administratorrechten ausgeführt.

### Valkey-Datenbanken anzeigen

Menüpunkt 2 und `./db-manager.sh list all` zeigen auch Valkey an. `./db-manager.sh list valkey` zeigt nur Valkey. Die Ausgabe von `INFO keyspace` enthält pro belegter nummerierter Datenbank Schlüsselanzahl (`keys`), Schlüssel mit Ablaufzeit (`expires`) und mittlere Restlaufzeit (`avg_ttl`, Millisekunden). Leere Datenbanken werden nicht aufgeführt; ist Valkey leer, erscheint eine ausdrückliche Meldung.

### Valkey-Clients zuordnen

Die Valkey-Anzeige ergänzt `CLIENT LIST` um ACL-Benutzer, Client-Adresse, ausgewählte DB und Client-Namen. IP-Adressen werden mit IPv4/IPv6-Adressen aus `docker network inspect` der lokal an Valkey angeschlossenen Netzwerke verglichen. Mehrere Treffer werden angezeigt. Das ist eine Momentaufnahme und ein IP-Abgleich, kein sicherer Identitätsnachweis: gemeinsame ACL-Benutzer (`default`), NAT, andere Docker-Hosts und Host-Netzwerke begrenzen die Zuordnung. Nicht verbundene Anwendungen sind nicht sichtbar.
