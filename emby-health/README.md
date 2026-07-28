# Emby Health Report 2.1 für Synology

## Enthaltene Prüfungen

- fehlende Staffeln
- fehlende Episoden
- Filme/Episoden ohne deutsche Audiospur
- Filme/Episoden ohne deutsche Untertitel
- Medien ohne wesentliche Metadaten
- Medien unter der eingestellten Mindestauflösung
- unbekannte Auflösung
- unbekannte Audiosprache
- doppelte Filme
- doppelte Episoden
- HTML-Mail und HTML-Bericht
- JSON-Export
- SQLite-Verlauf
- Vergleich mit dem vorherigen Lauf
- Episoden nach Serie und Staffel gruppiert und aufklappbar

## Installation auf Synology

1. ZIP nach folgendem Ordner entpacken:

```text
/volume1/scripts/emby-health/
```

2. Per SSH:

```bash
cd /volume1/scripts/emby-health
chmod +x install.sh run.sh emby_health_report.py
./install.sh
```

Falls Python nicht unter `/usr/bin/python3` liegt:

```bash
PYTHON=/usr/local/bin/python3 ./install.sh
```

3. `config.ini` bearbeiten.

Wichtig:

```ini
[emby]
url = http://127.0.0.1:8096
api_key = DEIN_EMBY_API_KEY
```

MailPlus lokal:

```ini
[mail]
smtp_host = 127.0.0.1
smtp_port = 25
smtp_user =
smtp_password =
starttls = false
ssl = false
from = emby@deinedomain.de
to = deinpostfach@deinedomain.de
```

4. Testlauf:

```bash
cd /volume1/scripts/emby-health
./run.sh
```

## Synology Aufgabenplaner

DSM:

```text
Systemsteuerung → Aufgabenplaner → Erstellen
→ Geplante Aufgabe → Benutzerdefiniertes Skript
```

Als Skript:

```sh
/volume1/scripts/emby-health/run.sh >> /volume1/scripts/emby-health/task.log 2>&1
```

Empfehlung: einmal pro Woche nach dem Emby-Bibliotheksscan.

## Erzeugte Dateien

```text
reports/report-latest.html
reports/emby-health-DATUM_UHRZEIT.html
reports/emby-health-DATUM_UHRZEIT.json
emby_health.sqlite3
emby_health.log
```

## Hinweise zu MailPlus

Bei `127.0.0.1:25` muss MailPlus den lokalen Absender akzeptieren. Falls im Log
`Relay access denied` erscheint, musst du entweder SMTP-Authentifizierung
aktivieren oder in MailPlus eine passende Relay-Regel für localhost einrichten.

## Metadatenmodus

`strict` meldet nur Medien, bei denen die wichtigsten Metadaten praktisch
vollständig fehlen.

`any` meldet bereits ein einzelnes fehlendes geprüftes Feld.


## HTML-Sprache Deutsch/Englisch

In `config.ini` unter `[report]` wählen:

```ini
language = de
```

oder:

```ini
language = en
```

Übersetzt werden Dashboard, Überschriften, Tabellen, Statusmeldungen und aufklappbare Serien-/Staffelgruppen.
