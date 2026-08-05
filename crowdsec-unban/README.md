# CrowdSec Unban

Passwortgeschützte Notfall-Weboberfläche zum Prüfen und Entsperren der eigenen IPv4-/IPv6-Adresse auf einem CrowdSec-VPS. CrowdSec und Docker werden nicht öffentlich erreichbar gemacht; der Webspace kommuniziert über einen eingeschränkten SSH-Schlüssel mit dem VPS.

## Funktionen

- aktive CrowdSec-Entscheidungen und zugehörige Alerts anzeigen
- Sperrgrund, Maßnahme, Restdauer, Provider, ASN und Land darstellen
- eigene erkannte Besucher-IP entsperren
- alle Entscheidungen löschen – ausschließlich für konfigurierte Administratoren
- Benutzer-, Passwort- und SSH-Schlüsselverwaltung im Adminbereich
- CSRF-Schutz, Rate-Limits, Audit-Protokoll und zweistufige Bestätigungen
- IPv4, IPv6 und kontrollierte Reverse-Proxy-Unterstützung
- Webspace-Diagnose mit `check.php`
- VPS-Installer mit Backup, sudoers-Prüfung und Rücksicherung

## Standardzugang

Nach der ersten Installation:

```text
Benutzer: admin
Passwort: admin
```

> **Sofort nach der ersten Anmeldung über `admin.php` ändern.** Diese öffentlich bekannte Kombination ist ausschließlich für die Ersteinrichtung vorgesehen und bietet keinen dauerhaften Schutz.

## Schnellinstallation

### 1. SSH-Schlüssel erzeugen

Auf einem vertrauenswürdigen Rechner:

```bash
ssh-keygen -t ed25519 -f crowdsec_rescue -C crowdsec-rescue
```

Für den automatischen Betrieb darf der Schlüssel keine interaktive Passphrase benötigen. Den privaten Schlüssel niemals nach GitHub hochladen.

### 2. VPS vorbereiten

```bash
sudo useradd --create-home --shell /bin/bash rescue
sudo passwd --lock rescue
sudo install -d -o rescue -g rescue -m 0700 /home/rescue/.ssh
```

Den Inhalt von `crowdsec_rescue.pub` in `/home/rescue/.ssh/authorized_keys` eintragen, davor den Forced Command setzen:

```text
command="/usr/local/bin/crowdsec-rescue-wrapper",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... crowdsec-rescue
```

Danach:

```bash
sudo chown rescue:rescue /home/rescue/.ssh/authorized_keys
sudo chmod 0600 /home/rescue/.ssh/authorized_keys
```

Den Ordner `VPS` auf den Server kopieren und ausführen:

```bash
cd VPS
sudo bash install-vps.sh
```

Der SSH-Schlüssel erhält keine Shell. Er kann nur die im Wrapper fest definierten Befehle `STATUS`, `ALERTS`, `UNBAN` und `UNBAN_ALL` an die fest hinterlegten Root-Skripte weiterreichen. Port-, Agent- und X11-Weiterleitung sowie ein Terminal sind deaktiviert.

### 3. Webspace installieren

Die Struktur muss so aussehen:

```text
WEBSPACE/
├── config.php
├── crowdsec_rescue       echter privater Schlüssel, nicht aus Git
├── .htpasswd
└── public/
    ├── .htaccess
    ├── index.php
    ├── admin.php
    └── check.php
```

1. `crowdsec_rescue.example` nach `crowdsec_rescue` kopieren und durch den echten privaten Schlüssel ersetzen.
2. `config.php` anpassen: Servername, VPS-IP, SSH-Port und gegebenenfalls Proxy-IP.
3. In `public/.htaccess` den absoluten Webspace-Pfad bei `AuthUserFile` eintragen.
4. Den VPS-Hostschlüssel verifizieren und in `known_hosts` des PHP-/Hosting-Benutzers aufnehmen.
5. Berechtigungen setzen: Schlüssel und `.htpasswd` `0600`, PHP-Dateien und `.htaccess` `0644`.
6. Nur `public/` als DocumentRoot der Domain konfigurieren.
7. `https://DEINE-DOMAIN/check.php` öffnen und alle Fehler beheben.
8. Mit `admin` / `admin` anmelden und das Passwort sofort über `admin.php` ändern.

## Rollen

- Normale Benutzer dürfen Status/Alerts prüfen und ausschließlich ihre automatisch erkannte IP entsperren.
- Nur Namen aus `admin_users` in `config.php` dürfen `admin.php` öffnen und sämtliche CrowdSec-Entscheidungen löschen.
- Die Adminprüfung erfolgt zusätzlich serverseitig; das bloße Nachbauen eines Formularaufrufs reicht nicht aus.

## Dokumentation

Weitere technische Details, Sicherheitsfunktionen, Tests und Fehlerbehebung stehen in [DOCS.md](DOCS.md). Eine lineare Installationsanleitung befindet sich in [VPS/INSTALLATION.txt](VPS/INSTALLATION.txt).
