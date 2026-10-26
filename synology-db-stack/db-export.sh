#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pg-tools.sh"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/my-tools.sh"

BASE="${DB_MANAGER_BASE:-/volume1/docker/stack_database}"
BACKUPS="$BASE/backups"
PROFILES="$BASE/external-db-profiles"
mkdir -p "$BACKUPS/mariadb" "$BACKUPS/postgres" "$PROFILES"
chmod 700 "$BACKUPS/mariadb" "$BACKUPS/postgres" "$PROFILES"

die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }
notice() { printf '%s\n' "$*" >&2; }
valid_id() { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,30}$ ]]; }
valid_host() { [[ -n "$1" && "$1" != *[$'\n\r']* ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
ask() { local answer; read -r -p "$1" answer || exit 1; printf '%s' "$answer"; }
password_prompt() {
  local value
  read -r -s -p 'Passwort (leer nur bei explizit passwortloser Authentifizierung): ' value || exit 1
  printf '\n' >&2
  DB_PASSWORD="$value"
}

# Profile format is deliberately parsed, never sourced/executed.
load_profile() {
  local file="$PROFILES/$1.conf" key val
  [[ -f "$file" && ! -L "$file" ]] || die 'Profil nicht gefunden'
  PROFILE_NAME="$1"; KIND=''; ENGINE=''; TARGET=''; PORT=''; DB_USER=''; MAINT_DB=''
  while IFS='=' read -r key val || [[ -n "$key" ]]; do
    case "$key" in
      KIND) KIND="$val" ;; ENGINE) ENGINE="$val" ;; TARGET) TARGET="$val" ;;
      PORT) PORT="$val" ;; DB_USER) DB_USER="$val" ;; MAINT_DB) MAINT_DB="$val" ;;
      '') ;; *) die "Unbekanntes Profilfeld: $key" ;;
    esac
  done < "$file"
  [[ "$KIND" == docker || "$KIND" == tcp ]] || die 'Ungültiges Profil'
  [[ "$ENGINE" == mariadb || "$ENGINE" == postgres ]] || die 'Ungültiger Datenbanktyp'
  [[ -n "$DB_USER" && "$DB_USER" != *[$'\n\r']* ]] || die 'Ungültiger Benutzer'
  [[ -n "$TARGET" ]] || die 'Ungültiges Ziel'
  valid_port "$PORT" || die 'Ungültiger Port'
  [[ -n "$MAINT_DB" ]] || die 'Fehlende Wartungsdatenbank'
  DB_PASSWORD="$(cat "$PROFILES/$1.secret")" || die 'Passwortdatei nicht lesbar'
}

create_profile() {
  local name selection default_port pass
  name="$(ask 'Profilname [a-z0-9_] (beginnt mit Buchstaben): ')"
  valid_id "$name" || die 'Profilname ungültig'
  [[ ! -e "$PROFILES/$name.conf" && ! -e "$PROFILES/$name.secret" ]] || die 'Profil existiert bereits'
  printf '1) Docker-Container  2) TCP/IP (anderer PC/Server)\n'
  selection="$(ask 'Verbindung: ')"
  case "$selection" in 1) KIND=docker ;; 2) KIND=tcp ;; *) die 'Ungültige Auswahl';; esac
  printf '1) MariaDB/MySQL  2) PostgreSQL\n'
  selection="$(ask 'Datenbanktyp: ')"
  case "$selection" in 1) ENGINE=mariadb; default_port=3306 ;; 2) ENGINE=postgres; default_port=5432 ;; *) die 'Ungültige Auswahl';; esac
  if [[ "$KIND" == docker ]]; then
    command -v docker >/dev/null || die 'Docker CLI fehlt'
    docker ps --format 'table {{.Names}}\t{{.Image}}'
    TARGET="$(ask 'Containername: ')"
    [[ "$TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'Ungültiger Containername'
    docker inspect "$TARGET" >/dev/null || die 'Container nicht vorhanden'
    notice 'Verbindung erfolgt innerhalb des Containers über TCP 127.0.0.1.'
  else
    TARGET="$(ask 'IP-Adresse / Hostname: ')"
    valid_host "$TARGET" || die 'Ungültige IP/Hostname'
  fi
  PORT="$(ask "Port [$default_port]: ")"; PORT="${PORT:-$default_port}"
  valid_port "$PORT" || die 'Ungültiger Port'
  DB_USER="$(ask 'DB-Benutzer: ')"; [[ -n "$DB_USER" && "$DB_USER" != *[$'\n\r']* ]] || die 'Benutzer fehlt'
  MAINT_DB="$(ask "Wartungsdatenbank [$( [[ "$ENGINE" == postgres ]] && echo postgres || echo mysql )]: ")"
  MAINT_DB="${MAINT_DB:-$( [[ "$ENGINE" == postgres ]] && echo postgres || echo mysql )}"
  valid_id "$MAINT_DB" || die 'Wartungsdatenbank muss [a-z][a-z0-9_]{0,30} entsprechen'
  password_prompt
  { printf 'KIND=%s\nENGINE=%s\nTARGET=%s\nPORT=%s\nDB_USER=%s\nMAINT_DB=%s\n' "$KIND" "$ENGINE" "$TARGET" "$PORT" "$DB_USER" "$MAINT_DB"; } > "$PROFILES/$name.conf"
  printf '%s' "$DB_PASSWORD" > "$PROFILES/$name.secret"
  chmod 600 "$PROFILES/$name.conf" "$PROFILES/$name.secret"
  PROFILE_NAME="$name"
  notice "Profil '$name' gespeichert (Dateirechte 600)."
}

select_profile() {
  local -a names=() ; local i sel f
  shopt -s nullglob
  for f in "$PROFILES"/*.conf; do names+=("$(basename "$f" .conf)"); done
  shopt -u nullglob
  ((${#names[@]})) || die 'Keine Profile vorhanden. Zuerst Profil anlegen.'
  for i in "${!names[@]}"; do printf '%d) %s\n' "$((i+1))" "${names[i]}"; done
  sel="$(ask 'Profilnummer: ')"
  [[ "$sel" =~ ^[0-9]+$ ]] || die 'Ungültige Auswahl'
  ((sel>=1 && sel<=${#names[@]})) || die 'Ungültige Auswahl'
  load_profile "${names[sel-1]}"
}

# Array commands avoid shell interpolation and avoid passwords in process arguments.
client() {
  local -a cmd=()
  if [[ "$ENGINE" == mariadb ]]; then
    external_my_settings
    my_tools_detect || return 1
    my_tools_client "$MY_IMAGE" "$MY_CLIENT" "$@"
    return
  else
    external_pg_settings
    pg_tools_client "${PG_BOOTSTRAP_MAJOR:-18}" psql -X -v ON_ERROR_STOP=1 "$@"
    return
  fi
  "${cmd[@]}" "$@"
}

external_my_settings() {
  MY_KIND="$KIND"; MY_TARGET="$TARGET"; MY_PORT="$PORT"
  MY_USER="$DB_USER"; MY_PASSWORD="$DB_PASSWORD"
}

external_pg_settings() {
  PG_KIND="$KIND"; PG_TARGET="$TARGET"; PG_PORT="$PORT"
  PG_USER="$DB_USER"; PG_PASSWORD="$DB_PASSWORD"
}

list_databases() {
  if [[ "$ENGINE" == mariadb ]]; then
    client -N -B "$MAINT_DB" -e \
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys') ORDER BY schema_name"
  else
    client -A -t -d "$MAINT_DB" -c \
      "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY datname"
  fi
}

test_connection() {
  if [[ "$ENGINE" == mariadb ]]; then client -N -B "$MAINT_DB" -e 'SELECT VERSION();'
  else client -A -t -d "$MAINT_DB" -c 'SELECT version();' ; fi
}

backup_one() {
  local name="$1" stamp dir file tmp meta
  valid_id "$name" || { notice "Übersprungen: inkompatibler Datenbankname '$name'"; return 1; }
  dir="$BACKUPS/$ENGINE"; stamp="$(date +%Y%m%d_%H%M%S)"
  if [[ "$ENGINE" == mariadb ]]; then file="$dir/${name}_${stamp}.sql.gz"
  else file="$dir/${name}_${stamp}.dump"; fi
  [[ ! -e "$file" ]] || { notice "Datei existiert bereits: $file"; return 1; }
  tmp="$(mktemp "$dir/.incomplete.XXXXXXXX")" || return 1
  notice "Sichere $PROFILE_NAME ($TARGET): $name"
  if [[ "$ENGINE" == mariadb ]]; then
    external_my_settings
    my_tools_detect || { rm -f "$tmp"; return 1; }
    notice "MariaDB/MySQL-Werkzeuge: $MY_IMAGE"
    local -a dump_options=()
    if [[ "$MY_DUMP" == mysqldump ]]; then
      dump_options+=(--set-gtid-purged=OFF --no-tablespaces)
      if (( ${MY_VERSION%%.*} >= 8 )); then dump_options+=(--column-statistics=0); fi
    fi
    if ! my_tools_client "$MY_IMAGE" "$MY_DUMP" "${dump_options[@]}" \
      --single-transaction --routines --events --triggers --hex-blob -- "$name" | gzip > "$tmp"; then
      rm -f "$tmp"; notice 'Dump fehlgeschlagen'; return 1
    fi
    if ! gzip -t "$tmp"; then rm -f "$tmp"; return 1; fi
  else
    external_pg_settings
    local major
    major="$(pg_tools_major "$MAINT_DB")" || { rm -f "$tmp"; return 1; }
    notice "PostgreSQL-Werkzeuge: postgres:$major"
    if ! pg_tools_client "$major" pg_dump -Fc -d "$name" > "$tmp"; then
      rm -f "$tmp"; notice 'Dump fehlgeschlagen'; return 1
    fi
    if [[ "$(head -c 5 "$tmp")" != PGDMP ]]; then
      rm -f "$tmp"; notice 'Kein gültiger PostgreSQL Custom-Dump'; return 1
    fi
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; notice 'Backup ist leer'; return 1; }
  chmod 600 "$tmp"
  mv -n "$tmp" "$file"
  [[ -e "$file" ]] || { rm -f "$tmp"; return 1; }
  ( cd "$dir" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256" )
  meta="$file.source.txt"
  printf 'Profil: %s\nQuelle: %s (%s)\nEngine: %s\nDB: %s\nZeit: %s\n' "$PROFILE_NAME" "$TARGET" "$KIND" "$ENGINE" "$name" "$(date -Is)" > "$meta"
  if [[ "$ENGINE" == postgres ]]; then printf 'PG_DUMP_MAJOR=%s\n' "$major" >> "$meta"; fi
  if [[ "$ENGINE" == mariadb ]]; then printf 'DUMP_IMAGE=%s\n' "$MY_IMAGE" >> "$meta"; fi
  chmod 600 "$meta"
  printf 'OK: %s\n' "$file"
}

backup_menu() {
  local choice selected failures=0 db
  local -a dbs=()
  select_profile
  notice 'Teste Verbindung ...'
  test_connection >/dev/null || die 'Verbindung fehlgeschlagen (Benutzer, Passwort, Port, DB, Rechte prüfen)'
  mapfile -t dbs < <(list_databases) # error may be suppressed by process substitution: explicit test below
  if ! list_databases >/dev/null; then die 'Datenbanken konnten nicht abgefragt werden'; fi
  ((${#dbs[@]})) || die 'Keine Anwendungsdatenbanken gefunden'
  printf '0) Alle Datenbanken sichern\n'
  for choice in "${!dbs[@]}"; do printf '%d) %s\n' "$((choice+1))" "${dbs[choice]}"; done
  selected="$(ask 'Auswahl: ')"
  [[ "$selected" =~ ^[0-9]+$ ]] || die 'Ungültige Auswahl'
  if ((selected==0)); then
    for db in "${dbs[@]}"; do backup_one "$db" || ((++failures)); done
    ((failures==0)) || die "$failures Sicherungen fehlgeschlagen"
  else
    ((selected <= ${#dbs[@]})) || die 'Ungültige Auswahl'
    backup_one "${dbs[selected-1]}" || die 'Backup fehlgeschlagen'
  fi
}

show_backups() {
  find "$BACKUPS/mariadb" "$BACKUPS/postgres" -maxdepth 1 -type f \
    \( -name '*.sql.gz' -o -name '*.dump' \) -print | sort -r
}

main() {
  local opt
  while :; do
    printf '\n=== EXTERNAL DATABASE BACKUP MANAGER ===\n'
    printf '1) Verbindung speichern\n2) Verbindung testen\n3) Datenbank sichern / alle sichern\n4) Backups anzeigen\n0) Beenden\n'
    opt="$(ask 'Auswahl: ')"
    case "$opt" in
      1) create_profile ;;
      2) select_profile; test_connection ;;
      3) backup_menu ;;
      4) show_backups ;;
      0) break ;;
      *) notice 'Ungültige Auswahl' ;;
    esac
  done
}
main "$@"
