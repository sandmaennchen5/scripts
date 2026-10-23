#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREDS="$BASE/credentials"
BACKUPS="$BASE/backups"
mkdir -p "$CREDS" "$BACKUPS"
chmod 700 "$CREDS" "$BACKUPS"
[ -f "$BASE/.env" ] || { echo "Missing $BASE/.env (copy .env.example)" >&2; exit 1; }
# .env is trusted local admin input; keep chmod 600
set -a
# shellcheck disable=SC1091
source "$BASE/.env"
set +a
: "${MARIADB_ROOT_PASSWORD:?}" "${POSTGRES_ADMIN_PASSWORD:?}" "${VALKEY_PASSWORD:?}"
pg() { docker exec -i -u postgres database-postgres psql -X -v ON_ERROR_STOP=1 "$@"; }
my() { docker exec -i -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" database-mariadb mariadb -uroot "$@"; }
require_name() { [[ "${1:-}" =~ ^[a-z][a-z0-9_]{0,30}$ ]] || { echo 'Name must match [a-z][a-z0-9_]{0,30}' >&2; exit 1; }; }
require_engine() { [[ "${1:-}" == postgres || "${1:-}" == mariadb ]] || { echo 'Use postgres or mariadb' >&2; exit 1; }; }
confirm() { local prompt="$1" typed; read -r -p "Type ${prompt} to proceed: " typed; [[ "$typed" == "$prompt" ]] || { echo 'Canceled'; exit 1; }; }
exists_pg() { pg -At -d postgres -c "SELECT (EXISTS(SELECT 1 FROM pg_roles WHERE rolname='$1') OR EXISTS(SELECT 1 FROM pg_database WHERE datname='$1'))::int"; }
exists_my() { my -N -e "SELECT ((SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$1')+(SELECT COUNT(*) FROM mysql.user WHERE User='$1'))"; }
create() {
  local eng="$1" name="$2" pwd file
  require_engine "$eng"; require_name "$name"
  file="$CREDS/${name}-${eng}.env"
  [[ ! -e "$file" ]] || { echo "Already exists: $file" >&2; exit 1; }
  pwd="$(openssl rand -hex 32)"
  if [[ "$eng" == postgres ]]; then
    [[ "$(exists_pg "$name")" == 0 ]] || { echo 'Existing database or user' >&2; exit 1; }
    # Validate quoted SQL values: restricted name and hex-only password.
    printf 'CREATE ROLE "%s" LOGIN PASSWORD '\''%s'\'';\nCREATE DATABASE "%s" OWNER "%s";\n' "$name" "$pwd" "$name" "$name" | pg -d postgres
    host=database-postgres; port=5432
  else
    [[ "$(exists_my "$name")" == 0 ]] || { echo 'Existing database or user' >&2; exit 1; }
    printf "CREATE DATABASE \`%s\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\nCREATE USER '%s'@'%%' IDENTIFIED BY '%s';\nGRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\n" "$name" "$name" "$pwd" "$name" "$name" | my
    host=database-mariadb; port=3306
  fi
  { printf 'DB_HOST=%s\nDB_PORT=%s\nDB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\n' "$host" "$port" "$name" "$name" "$pwd"; } > "$file"
  chmod 600 "$file"
  echo "Created. Credentials: $file (restricted to administrator)."
}
listdb() {
  case "$1" in
    postgres) pg -d postgres -c 'SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname' ;;
    mariadb) my -e 'SHOW DATABASES;' ;;
    all) listdb postgres; listdb mariadb ;;
    *) echo 'Use postgres|mariadb|all' >&2; exit 1;;
  esac
}
status() { docker ps --filter 'name=database-' --format 'table {{.Names}}\t{{.Status}}'; }
backup() {
  local eng="$1" name="${2:-all}" stamp dir file
  [[ "$eng" == all || "$eng" == postgres || "$eng" == mariadb || "$eng" == valkey ]] || exit 1
  if [[ "$eng" == all ]]; then backup postgres all; backup mariadb all; backup valkey all; return; fi
  [[ "$name" == all ]] || require_name "$name"
  [[ "$eng" != valkey || "$name" == all ]] || { echo 'Valkey supports only full snapshot'; exit 1; }
  stamp="$(date +%Y%m%d_%H%M%S)"
  dir="$BACKUPS/$eng"; mkdir -p "$dir"; chmod 700 "$dir"
  file="$dir/${name}_${stamp}"
  case "$eng:$name" in
    postgres:all)
      docker exec -u postgres database-postgres pg_dumpall -U postgres | gzip > "${file}.sql.gz" ;;
    postgres:*)
      docker exec -u postgres database-postgres pg_dump -U postgres -Fc -d "$name" > "${file}.dump" ;;
    mariadb:all)
      docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" database-mariadb mariadb-dump -uroot --all-databases --single-transaction --routines --events --triggers --hex-blob | gzip > "${file}.sql.gz" ;;
    mariadb:*)
      docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" database-mariadb mariadb-dump -uroot --single-transaction --routines --events --triggers --hex-blob "$name" | gzip > "${file}.sql.gz" ;;
    valkey:all)
      echo 'Pausing Valkey (applications may be temporarily affected)...'
      (
        trap 'docker start database-valkey >/dev/null || true' EXIT
        docker stop database-valkey >/dev/null
        tar -czf "${file}.tar.gz" -C "$BASE/valkey" data
      ) ;;
  esac
  (cd "$dir" && sha256sum "$(basename "${file}")"* > "$(basename "${file}").sha256")
  echo "Backup created: ${file}.*"
}
# Restore only a named single-database backup. Existing targets require an explicit
# destructive flag, a fresh safety backup, and a typed confirmation.
restore() {
  local eng="$1" name="$2" file="$3" mode="${4:-safe}" abs tables owner
  require_engine "$eng"; require_name "$name"
  [[ "$mode" == safe || "$mode" == overwrite ]] || { echo 'Mode: safe|overwrite' >&2; return 2; }
  [[ -f "$file" ]] || { echo 'Backup not found' >&2; return 1; }
  abs="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
  [[ "$abs" == "$BACKUPS/$eng/"* ]] || { echo 'Use files in the engine backup directory' >&2; return 1; }
  case "$eng" in
    postgres) [[ "$abs" == *.dump ]] || { echo 'Expected .dump file' >&2; return 1; } ;;
    mariadb) [[ "$abs" == *.sql.gz ]] || { echo 'Expected .sql.gz file' >&2; return 1; }; gzip -t "$abs" ;;
  esac
  echo "STOP application clients before restoring $eng/$name."
  if [[ "$eng" == postgres ]]; then
    owner="$(pg -At -d postgres -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$name'")"
    [[ -n "$owner" ]] || { echo 'Database does not exist. Create target first.' >&2; return 1; }
    tables="$(pg -At -d "$name" -c "SELECT count(*) FROM pg_class WHERE relkind IN ('r','p','v','m','S','f') AND relnamespace NOT IN (SELECT oid FROM pg_namespace WHERE nspname LIKE 'pg_%' OR nspname='information_schema')")"
  else
    [[ "$(my -N -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$name'")" == 1 ]] || { echo 'Database does not exist. Create target first.' >&2; return 1; }
    tables="$(my -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$name'")"
  fi
  if [[ "$mode" == safe && "$tables" != 0 ]]; then
    echo 'Database is not empty. Select overwrite explicitly to replace existing data.' >&2; return 1
  fi
  if [[ "$mode" == overwrite ]]; then
    echo "WARNING: database $eng/$name WILL BE ERASED."
    confirm "OVERWRITE $eng $name"
    echo 'Creating mandatory safety backup...'
    backup "$eng" "$name" || { echo 'Safety backup failed; aborting.' >&2; return 1; }
    if [[ "$eng" == postgres ]]; then
      # Drop/recreate via admin database while preserving database owner.
      pg -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$name' AND pid <> pg_backend_pid()" >/dev/null
      pg -d postgres -c "DROP DATABASE \"$name\" WITH (FORCE)" 
      pg -d postgres -c "CREATE DATABASE \"$name\" OWNER \"$owner\""
    else
      my -e "DROP DATABASE \`$name\`; CREATE DATABASE \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    fi
  else
    confirm "RESTORE $eng $name"
  fi
  if [[ "$eng" == postgres ]]; then
    docker exec -i -u postgres database-postgres pg_restore -U postgres --role="$owner" --no-owner --no-privileges --exit-on-error -d "$name" < "$abs"
  else
    gzip -dc "$abs" | my "$name"
  fi
  echo 'Restore command finished. Verify health, permissions, and application data before restarting clients.'
}
backup_choices() {
  local eng="$1" name="$2" f i=0 selected
  local -a files=()
  shopt -s nullglob
  if [[ "$eng" == postgres ]]; then
    files=("$BACKUPS/postgres/${name}_"*.dump)
  elif [[ "$eng" == mariadb ]]; then
    files=("$BACKUPS/mariadb/${name}_"*.sql.gz)
  else
    files=("$BACKUPS/valkey/all_"*.tar.gz)
  fi
  shopt -u nullglob
  ((${#files[@]})) || { echo 'No matching backups found' >&2; return 1; }
  mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -r)
  echo 'Available backups (newest first):' >&2
  for f in "${files[@]}"; do
    ((++i))
    printf '%d) %s\n' "$i" "$(basename "$f")" >&2
  done
  read -r -p 'Choose backup number [1], 0 cancels: ' selected
  selected="${selected:-1}"
  [[ "$selected" =~ ^[0-9]+$ ]] || return 1
  (( selected >= 1 && selected <= ${#files[@]} )) || return 1
  printf '%s\n' "${files[selected-1]}"
}
select_engine() {
  local option
  echo '1) PostgreSQL  2) MariaDB  3) Valkey' >&2
  read -r -p 'Select engine: ' option
  case "$option" in 1) echo postgres;; 2) echo mariadb;; 3) echo valkey;; *) return 1;; esac
}
select_db() {
  local eng="$1" line selected i=0
  local -a dbs=()
  if [[ "$eng" == postgres ]]; then
    mapfile -t dbs < <(pg -At -d postgres -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname <> 'postgres' ORDER BY datname")
  else
    mapfile -t dbs < <(my -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys') ORDER BY schema_name")
  fi
  ((${#dbs[@]})) || { echo 'No application databases' >&2; return 1; }
  for line in "${dbs[@]}"; do ((++i)); printf '%d) %s\n' "$i" "$line" >&2; done
  read -r -p 'Database number (0 cancels): ' selected
  [[ "$selected" =~ ^[0-9]+$ ]] && (( selected>=1 && selected<=${#dbs[@]} )) || return 1
  printf '%s\n' "${dbs[selected-1]}"
}
restore_valkey() {
  local file="$1" abs
  [[ -f "$file" && "$file" == *.tar.gz ]] || { echo 'Expected .tar.gz'; exit 1; }
  abs="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
  [[ "$abs" == "$BACKUPS/valkey/"* ]] || { echo 'Must be a Valkey archive under backups/valkey'; exit 1; }
  [[ "$(tar -tzf "$file" | grep -Ec '^data(/|$)')" -ge 1 ]] || exit 1
  echo 'STOP ALL Valkey clients before restoring.'
  confirm 'RESTORE VALKEY'
  docker stop database-valkey >/dev/null
  # Keep old data if archive is corrupt / restore fails.
  local old="$BASE/valkey/data.before-restore-$(date +%s)"
  mv "$BASE/valkey/data" "$old"
  if ! tar -xzf "$file" -C "$BASE/valkey"; then
    rm -rf "$BASE/valkey/data"; mv "$old" "$BASE/valkey/data"
    docker start database-valkey >/dev/null || true
    echo 'Restore failed; original data restored.' >&2; exit 1
  fi
  docker start database-valkey >/dev/null
  echo "Valkey restored. Previous data preserved at: $old"
}
rotate() {
  local eng="$1" name="$2" pwd file
  require_engine "$eng"; require_name "$name"
  file="$CREDS/${name}-${eng}.env"
  [[ -f "$file" ]] || { echo "No managed credential file: $file" >&2; exit 1; }
  confirm "ROTATE $eng $name"
  pwd="$(openssl rand -hex 32)"
  if [[ "$eng" == postgres ]]; then
    printf "ALTER ROLE \"%s\" PASSWORD '%s';\n" "$name" "$pwd" | pg -d postgres
  else
    printf "ALTER USER '%s'@'%%' IDENTIFIED BY '%s';\n" "$name" "$pwd" | my
  fi
  sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$pwd/" "$file"
  chmod 600 "$file"
  echo "Password changed. Update application secrets using: $file"
}
menu() {
  local opt eng name file mode choice
  while true; do
    printf '\n========== SYNOLOGY DATABASE MANAGER ==========\n'
    printf '1) Status\n2) Datenbanken auflisten\n3) Datenbank + Benutzer anlegen\n4) Backup aller Dienste\n5) Einzel-Backup\n6) SQL-Restore (Backup-Auswahl)\n7) App-Passwort erneuern\n8) Valkey-Restore (Backup-Auswahl)\n9) Backups anzeigen\n0) Beenden\n'
    read -r -p 'Auswahl: ' opt || break
    case "$opt" in
      1) status ;;
      2) listdb all ;;
      3) eng="$(select_engine)" || continue; [[ "$eng" != valkey ]] || { echo 'Valkey nutzt ACL; SQL-Datenbankanlage nicht möglich.'; continue; }; read -r -p 'Neuer Anwendungsname: ' name; create "$eng" "$name" ;;
      4) backup all ;;
      5) eng="$(select_engine)" || continue; if [[ "$eng" == valkey ]]; then backup valkey; else name="$(select_db "$eng")" || continue; backup "$eng" "$name"; fi ;;
      6) eng="$(select_engine)" || continue; [[ "$eng" != valkey ]] || { echo 'Für Valkey Menüpunkt 8 verwenden'; continue; }; name="$(select_db "$eng")" || continue; file="$(backup_choices "$eng" "$name")" || continue
         echo '1) Nur in leere DB wiederherstellen  2) Vorhandene DB überschreiben  0) Abbrechen'; read -r -p 'Auswahl: ' choice
         case "$choice" in 1) mode=safe ;; 2) mode=overwrite ;; *) continue ;; esac
         restore "$eng" "$name" "$file" "$mode" ;;
      7) eng="$(select_engine)" || continue; [[ "$eng" != valkey ]] || continue; name="$(select_db "$eng")" || continue; rotate "$eng" "$name" ;;
      8) file="$(backup_choices valkey all)" || continue; restore_valkey "$file" ;;
      9) find "$BACKUPS" -type f \( -name '*.dump' -o -name '*.sql.gz' -o -name '*.tar.gz' \) | sort -r ;;
      0) break ;;
      *) echo 'Ungültige Auswahl' ;;
    esac
  done
}
case "${1:-menu}" in
 menu) menu ;;
 status) status ;;
 list) listdb "${2:-all}" ;;
 create) [[ $# == 3 ]] || exit 2; create "$2" "$3" ;;
 backup) backup "${2:-all}" "${3:-all}" ;;
 restore) [[ $# -ge 4 && $# -le 5 ]] || exit 2; restore "$2" "$3" "$4" "${5:-safe}" ;;
 restore-valkey) [[ $# == 2 ]] || exit 2; restore_valkey "$2" ;;
 rotate) [[ $# == 3 ]] || exit 2; rotate "$2" "$3" ;;
 *) echo 'Usage: db-manager.sh [menu|status|list [postgres|mariadb|all]|create ENGINE NAME|backup [all|postgres|mariadb|valkey] [NAME|all]|restore ENGINE NAME FILE [safe|overwrite]|restore-valkey FILE|rotate ENGINE NAME]' >&2; exit 2 ;;
esac
