# Dokumentation

## 1. Zweck und Architektur

Die Anwendung stellt keine CrowdSec-API und keinen Docker-Port öffentlich bereit. Der Ablauf ist:

```text
Browser → HTTPS/Basic Auth → PHP-Webspace → SSH-Schlüssel → rescue-Benutzer
        → Forced Command → eng begrenztes sudo-Skript → Docker → CrowdSec cscli
```

Die Weboberfläche arbeitet ausschließlich mit der automatisch erkannten Besucher-IP. Eine frei wählbare IP-Eingabe existiert nicht.

## 2. Unterstützte Aktionen

| Webaktion | SSH-Befehl | CrowdSec-Befehl |
|---|---|---|
| Status prüfen | `STATUS <IP>` | `cscli decisions list --ip <IP> -o json` |
| Alert-Details | `ALERTS <IP>` | `cscli alerts list --ip <IP> --limit 5 -o json` |
| Eigene IP entsperren | `UNBAN <IP>` | `cscli decisions delete --ip <IP>` |
| Alle Sperren löschen | `UNBAN_ALL` | `cscli decisions delete --all` |

IPv4 und IPv6 werden in PHP und auf dem VPS validiert.

## 3. Webspace konfigurieren

Alle veränderbaren Angaben stehen in `WEBSPACE/config.php`:

```php
return [
    'page_title' => 'CrowdSec Notfall-Unban',
    'server_name' => 'Mein CrowdSec VPS',
    'server_description' => 'Produktivserver',
    'host' => '203.0.113.10', // Durch die echte VPS-IP ersetzen
    'port' => 22,
    'ssh_user' => 'rescue',
    'ssh_key' => __DIR__ . '/crowdsec_rescue',
    'admin_users' => ['admin'],
    'trusted_proxies' => [],
];
```

`config.php`, `.htpasswd` und `crowdsec_rescue` müssen außerhalb von `public/` liegen. Nur der Inhalt von `public/` darf direkt über den Browser erreichbar sein.

Der ausgelieferte Bootstrap-Zugang lautet `admin` / `admin`. Er ist öffentlich bekannt und muss unmittelbar nach der ersten Anmeldung über `admin.php` geändert werden. Die Vorlage `crowdsec_rescue.example` enthält keinen echten Schlüssel und wird vor dem Upload nach `crowdsec_rescue` kopiert und vollständig ersetzt.

### Dateiberechtigungen

| Datei/Ordner | Empfehlung |
|---|---:|
| `crowdsec_rescue` | `0600` |
| `.htpasswd` | `0600` oder hosterbedingt `0640` |
| `config.php` | `0600` oder hosterbedingt `0640` |
| `public/.htaccess` | `0644` |
| `public/*.php` | `0644` |
| Verzeichnisse | `0750` oder hosterbedingt `0755` |
| Audit-/Rate-Limit-Dateien | automatisch `0600` |

Das Verzeichnis oberhalb von `public/` muss für PHP beschreibbar sein. Dort entstehen:

- `crowdsec_rescue_audit.log`
- `crowdsec_rescue_rate_limits.json`

### Basic Auth und Benutzerverwaltung

`public/.htaccess` schützt alle PHP-Seiten einschließlich `check.php` und `admin.php`. Der absolute Pfad bei `AuthUserFile` muss zum Webspace passen.

In `config.php` bestimmt `admin_users`, welche bereits in `.htpasswd` vorhandenen Benutzer die Verwaltung öffnen dürfen. Über `admin.php` können Benutzer angelegt, Passwörter geändert und Benutzer gelöscht werden. Passwörter müssen mindestens 12 Zeichen lang sein. Das aktuell angemeldete Administratorkonto kann sich nicht selbst löschen. Vor jeder Änderung wird `.htpasswd.backup` außerhalb des Webroots angelegt.

Neue Benutzer sind normale Benutzer. Für Administratorrechte muss ihr Name zusätzlich manuell in `admin_users` eingetragen werden.

Der Adminbereich zeigt außerdem Status, Größe und Berechtigung des privaten SSH-Schlüssels. Nach Eingabe von `SCHLÜSSEL ANZEIGEN` kann der Schlüssel bewusst eingeblendet und bearbeitet werden. Speichern verlangt zusätzlich `SCHLÜSSEL SPEICHERN`, prüft das OpenSSH-Format, legt `crowdsec_rescue.backup` an und setzt den neuen Schlüssel auf `0600`. Den Schlüssel nur auf einem vertrauenswürdigen Gerät anzeigen.

Die globale Aktion `UNBAN_ALL` ist ausschließlich für Namen aus `admin_users` verfügbar. Der Button wird für normale Benutzer nicht gerendert; zusätzlich verweigert die serverseitige Verarbeitung manipulierte Anfragen und schreibt den Versuch ins Audit-Protokoll.

Die SSH-Prüfung im Adminbereich führt ausschließlich `STATUS <aktuelle Besucher-IP>` aus. Sie verändert keine CrowdSec-Entscheidung und ist auf drei Tests pro Minute begrenzt.

### SSH-Hostschlüssel

Da `StrictHostKeyChecking=yes` aktiv ist, muss der Hostschlüssel des VPS im `known_hosts` des PHP-Benutzers stehen. Bei einem abweichenden SSH-Port lautet der Eintrag üblicherweise `[SERVER-IP]:PORT`.

## 4. VPS installieren

Den vollständigen Ordner `VPS` auf den Server kopieren und darin ausführen:

```bash
sudo bash install-vps.sh
```

Der Installer:

- prüft `rescue`, Docker, CrowdSec, Python, sudo und visudo
- sichert bestehende Dateien unter `/var/backups/crowdsec-rescue/`
- installiert Wrapper, Aktionsskripte und sudoers-Regel
- validiert die sudoers-Datei
- führt eine ungefährliche Statusabfrage für `192.0.2.1` aus
- stellt bei einem Installationsfehler den vorherigen Zustand wieder her

Entsperrbefehle werden bei der Installation nicht automatisch ausgeführt.

### Forced Command

Der öffentliche Schlüssel des Webspaces muss in `/home/rescue/.ssh/authorized_keys` mit einem Forced Command stehen:

```text
command="/usr/local/bin/crowdsec-rescue-wrapper",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 PUBLIC_KEY
```

Dadurch erhält der Schlüssel keinen allgemeinen Shellzugriff. Der Wrapper akzeptiert nur `STATUS`, `ALERTS`, `UNBAN` und den parameterlosen Befehl `UNBAN_ALL`.

## 5. Sicherheitsfunktionen

### CSRF-Schutz

Jede zustandsändernde Anfrage benötigt ein zufälliges Token aus einer HTTPS-Session. Das Session-Cookie ist `Secure`, `HttpOnly` und `SameSite=Strict`.

### Bestätigung für globales Löschen

Vor `UNBAN_ALL` muss auf einer zweiten Ansicht exakt `ALLE LÖSCHEN` eingegeben werden.

### Rate-Limits

| Aktion | Grenze |
|---|---:|
| Status | 5 pro Minute |
| eigene IP entsperren | 2 pro Minute |
| alle Sperren löschen | 1 pro 5 Minuten |

Kann der Rate-Limit-Speicher nicht sicher geöffnet werden, wird die Verwaltungsaktion nicht ausgeführt.

### Audit-Protokoll

Protokolliert werden UTC-Zeit, Basic-Auth-Benutzer, Besucher-IP, Aktion und Rückgabecode. Passwörter, private Schlüssel und CrowdSec-Ausgaben werden nicht gespeichert. Das Protokoll sollte regelmäßig rotiert und nach der benötigten Aufbewahrungszeit gelöscht werden.

### Reverse-Proxys

`X-Forwarded-For` wird nur akzeptiert, wenn `REMOTE_ADDR` exakt in `trusted_proxies` eingetragen ist. Ohne Eintrag wird ausschließlich `REMOTE_ADDR` verwendet. Niemals beliebige Proxybereiche eintragen.

## 6. Diagnose und Tests

Nach dem Upload `https://DEINE-DOMAIN/check.php` öffnen. Geprüft werden unter anderem:

- PHP-Version und `exec()`
- HTTPS und Basic Auth
- IPv4-/IPv6-Erkennung
- SSH-Programm und Schlüssel
- `.htaccess` und `.htpasswd`
- Schreibrechte und Dateiberechtigungen
- `known_hosts`

`check.php` führt keine CrowdSec-Aktion aus. Die Seite kann nach erfolgreicher Einrichtung entfernt werden.

VPS-Tests:

```bash
sudo -u rescue env SSH_ORIGINAL_COMMAND="STATUS 192.0.2.1" /usr/local/bin/crowdsec-rescue-wrapper
sudo -u rescue env SSH_ORIGINAL_COMMAND="ALERTS 192.0.2.1" /usr/local/bin/crowdsec-rescue-wrapper
sudo visudo -cf /etc/sudoers.d/crowdsec-rescue
docker exec crowdsec cscli decisions list
```

`UNBAN` und insbesondere `UNBAN_ALL` nur mit bewusst gewählten Testdaten prüfen.

## 7. Wartung und Wiederherstellung

- CrowdSec-Containername nach Updates kontrollieren; die Skripte erwarten `crowdsec`.
- SSH-Schlüssel regelmäßig erneuern.
- Audit-Protokoll und Rate-Limit-Datei kontrollieren und rotieren.
- Quartalsweise Status- und Entsperrfunktion testen.
- Vor Änderungen die Sicherungen unter `/var/backups/crowdsec-rescue/` prüfen.
- Nach einem VPS-Neuaufbau zuerst Docker/CrowdSec, dann den Benutzer `rescue`, den SSH-Schlüssel und zuletzt `install-vps.sh` einrichten.

## 8. Typische Fehler

| Meldung | Wahrscheinliche Ursache |
|---|---|
| `Permission denied (publickey)` | Schlüssel, `authorized_keys` oder Benutzer falsch |
| `Host key verification failed` | `known_hosts` fehlt oder VPS-Schlüssel wurde geändert |
| `UNPROTECTED PRIVATE KEY FILE` | Schlüsselberechtigung nicht `0600` |
| Statusantwort kein JSON | `cscli`-Version, Containername oder SSH-Ausgabe prüfen |
| Zu viele Aufrufe | Rate-Limit abwarten |
| Verwaltungsaktionen immer blockiert | Webspace-Verzeichnis für PHP nicht beschreibbar |
| Keine echte Besucher-IP | Reverse-Proxy-Konfiguration und `trusted_proxies` prüfen |

## 9. Datenschutz

IP-Adressen und Benutzernamen im Audit-Protokoll sind personenbezogene Betriebsdaten. Zugriff, Zweck, Aufbewahrungsdauer und Löschung sollten zur eigenen Datenschutzregelung passen.
