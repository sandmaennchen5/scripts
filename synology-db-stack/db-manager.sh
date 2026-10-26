#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pg-tools.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/my-tools.sh"
BASE="/volume1/docker/stack_database"
CREDS="$BASE/credentials"
BACKUPS="$BASE/backups"
mkdir -p "$CREDS" "$BACKUPS"
chmod 700 "$CREDS" "$BACKUPS"
[ -f ".env" ] || { echo "Missing .env (copy .env.example)" >&2; exit 1; }
# .env is trusted local admin input; keep chmod 600
set -a
# shellcheck disable=SC1091
source ".env"
set +a
: "${MARIADB_ROOT_PASSWORD:?}" "${POSTGRES_ADMIN_PASSWORD:?}" "${VALKEY_PASSWORD:?}"
pg() { docker exec -i -u postgres database-postgres psql -X -v ON_ERROR_STOP=1 "$@"; }
my() { docker exec -i -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" database-mariadb mariadb -uroot "$@"; }
require_name() { [[ "${1:-}" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,30}$ ]] || { echo 'Name must match [a-zA-Z][a-zA-Z0-9_]{0,30}' >&2; exit 1; }; }
require_engine() { [[ "${1:-}" == postgres || "${1:-}" == mariadb ]] || { echo 'Use postgres or mariadb' >&2; exit 1; }; }
confirm() { local prompt="$1" typed; read -r -p "Type ${prompt} to proceed: " typed; [[ "$typed" == "$prompt" ]] || { echo 'Canceled'; exit 1; }; }
exists_pg() { pg -At -d postgres -c "SELECT (EXISTS(SELECT 1 FROM pg_roles WHERE rolname='$1') OR EXISTS(SELECT 1 FROM pg_database WHERE datname='$1'))::int"; }
exists_my() { my -N -e "SELECT ((SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$1')+(SELECT COUNT(*) FROM mysql.user WHERE User='$1'))"; }
create() {
  local eng="$1" name="$2" pwd file
  require_engine "$eng"; require_name "$name"
  file="$CREDS/${name}-${eng}.env"
  [[ ! -e "$file" ]] || { echo "Already exists: $file" >&2; exit 1; }
  pwd="$(openssl rand -hex 16)"
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
list_valkey_clients() {
  local clients networks net rows mapping="" line field addr user db client_name cmd ip
  local -a fields=()
  local mapped_ip container network assignment ipv4 ipv6 found=0
  echo "=== Valkey: aktive Clients ==="
  if ! clients="$(VALKEYCLI_AUTH="$VALKEY_PASSWORD" docker exec -e VALKEYCLI_AUTH database-valkey valkey-cli -e --raw CLIENT LIST)"; then
    echo "FEHLER: Valkey-Clients konnten nicht abgefragt werden." >&2; return 1
  fi
  # Only inspect networks attached to Valkey, avoiding unrelated address spaces.
  if networks="$(docker inspect --type container --format '{{range $name, $config := .NetworkSettings.Networks}}{{println $name}}{{end}}' database-valkey)"; then
    while IFS= read -r net; do
      [[ -n "$net" ]] || continue
      if rows="$(docker network inspect --format '{{range .Containers}}{{printf "%s\t%s\t%s\n" .Name .IPv4Address .IPv6Address}}{{end}}' "$net")"; then
        while IFS=$'\t' read -r container ipv4 ipv6; do
          [[ -n "$container" ]] || continue
          for ip in "$ipv4" "$ipv6"; do
            [[ -n "$ip" ]] || continue
            printf -v mapping '%s%s\t%s\t%s\n' "$mapping" "${ip%/*}" "$container" "$net"
          done
        done <<< "$rows"
      else
        echo "Hinweis: Docker-Netzwerk $net konnte nicht gelesen werden." >&2
      fi
    done <<< "$networks"
  else
    echo "Hinweis: Docker-Zuordnung nicht verfügbar." >&2
  fi
  printf '%-16s %-26s %-6s %-20s %s\n' "ACL-Benutzer" "Client-Adresse" "DB" "Client-Name" "Container / Netzwerk (IP-Abgleich)"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    addr=""; user="?"; db="?"; client_name="-"; cmd=""
    read -r -a fields <<< "$line"
    for field in "${fields[@]}"; do
      case "$field" in
        addr=*) addr="${field#addr=}" ;;
        user=*) user="${field#user=}" ;;
        db=*) db="${field#db=}" ;;
        name=*) client_name="${field#name=}"; client_name="${client_name:--}" ;;
        cmd=*) cmd="${field#cmd=}" ;;
      esac
    done
    [[ -n "$addr" && "$cmd" != 'client|list' ]] || continue
    ip="${addr%:*}"; ip="${ip#[}"; ip="${ip%]}"
    assignment=""
    while IFS=$'\t' read -r mapped_ip container network; do
      if [[ "$mapped_ip" == "$ip" ]]; then
        assignment="${assignment:+$assignment; }$container / $network"
      fi
    done <<< "$mapping"
    assignment="${assignment:-nicht zugeordnet (extern / NAT / Host-Netz möglich)}"
    printf '%-16s %-26s %-6s %-20s %s\n' "$user" "$addr" "$db" "$client_name" "$assignment"
    found=1
  done <<< "$clients"
  if ((found == 0)); then echo "Keine weiteren aktiven Clients."; fi
  echo "Momentaufnahme: ACL-Benutzer sind keine sicheren App-/Personennamen; bei gemeinsamem Passwort meist default."
}

list_valkey() {
  local info line found=0
  echo "=== Valkey: belegte Datenbanken ==="
  if ! info="$(VALKEYCLI_AUTH="$VALKEY_PASSWORD" docker exec -e VALKEYCLI_AUTH database-valkey valkey-cli -e --raw INFO keyspace)"; then
    echo "FEHLER: Valkey-Datenbanken konnten nicht abgefragt werden." >&2; return 1
  fi
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^db[0-9]+: ]]; then
      printf "%s\n" "$line"
      found=1
    fi
  done <<< "$info"
  if ((found == 0)); then echo "Keine belegten Datenbanken (keine Schlüssel vorhanden)."; fi
  echo "Valkey verwendet nummerierte Datenbanken (db0, db1, ...); leere werden hier nicht angezeigt."
}

listdb() {
  case "$1" in
    postgres) echo '=== PostgreSQL: belegte Datenbanken ==='; pg -d postgres -c 'SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname' ;;
    mariadb) echo '=== MariaDB: belegte Datenbanken ==='; my -e 'SHOW DATABASES;' ;;
    valkey) list_valkey; list_valkey_clients ;;
    all) listdb postgres; listdb mariadb; listdb valkey ;;
    *) echo 'Use postgres|mariadb|valkey|all' >&2; exit 1;;
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
# Back up every application database separately, retaining the filenames expected
# by backup_choices()/restore(). Valkey has no SQL databases: one snapshot is used.
backup_each() {
  local eng db names count=0 failed=0
  local -a dbs=()
  for eng in postgres mariadb; do
    echo "=== Einzel-Backups: $eng ==="
    if [[ "$eng" == postgres ]]; then
      if ! names="$(pg -At -d postgres -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname <> 'postgres' AND datallowconn ORDER BY datname")"; then
        echo "FEHLER: Datenbankliste für $eng konnte nicht geladen werden." >&2
        ((failed+=1)); continue
      fi
    else
      if ! names="$(my -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys') ORDER BY schema_name")"; then
        echo "FEHLER: Datenbankliste für $eng konnte nicht geladen werden." >&2
        ((failed+=1)); continue
      fi
    fi
    dbs=()
    if [[ -n "$names" ]]; then mapfile -t dbs <<< "$names"; fi
    if ((${#dbs[@]} == 0)); then echo "Keine Anwendungsdatenbanken für $eng."; continue; fi
    for db in "${dbs[@]}"; do
      if [[ ! "$db" =~ ^[a-z][a-z0-9_]{0,30}$ ]]; then
        echo "FEHLER: Nicht kompatibler Datenbankname '$db' ($eng), übersprungen." >&2
        ((failed+=1)); continue
      fi
      echo "Sichere $eng/$db ..."
      if backup "$eng" "$db"; then
        ((count+=1))
      else
        echo "FEHLER: Backup $eng/$db fehlgeschlagen." >&2
        ((failed+=1))
      fi
    done
  done
  echo '=== Valkey-Snapshot ==='
  if backup valkey all; then ((count+=1)); else
    echo 'FEHLER: Valkey-Backup fehlgeschlagen.' >&2
    ((failed+=1))
  fi
  echo "Ergebnis: $count erfolgreiche Einzel-Backups/Snapshots, $failed Fehler."
  ((failed == 0))
}

# Restore only a named single-database backup. Existing targets require an explicit
# destructive flag, a fresh safety backup, and a typed confirmation.
restore() {
  local eng="$1" name="$2" file="$3" mode="${4:-safe}" abs tables owner target_major restore_major
  require_engine "$eng"; require_name "$name"
  [[ "$mode" == safe || "$mode" == overwrite ]] || { echo 'Mode: safe|overwrite' >&2; return 2; }
  [[ -f "$file" ]] || { echo 'Backup not found' >&2; return 1; }
  abs="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
  [[ "$abs" == "$BACKUPS/$eng/"* ]] || { echo 'Use files in the engine backup directory' >&2; return 1; }
  case "$eng" in
    postgres) [[ "$abs" == *.dump ]] || { echo 'Expected .dump file' >&2; return 1; } ;;
    mariadb) [[ "$abs" == *.sql.gz ]] || { echo 'Expected .sql.gz file' >&2; return 1; }; gzip -t "$abs" ;;
  esac
  if [[ "$eng" == postgres ]]; then
    PG_KIND=docker; PG_TARGET=database-postgres; PG_PORT=5432
    PG_USER=postgres; PG_PASSWORD="$POSTGRES_ADMIN_PASSWORD"
    target_major="$(pg_tools_major postgres)" || return 1
    restore_major="$(pg_tools_restore_major "$abs" "$target_major")" || return 1
    echo "Restore-Werkzeuge: postgres:$restore_major (Ziel: $target_major)"
  fi
  if [[ "$eng" == mariadb ]]; then
    MY_KIND=docker; MY_TARGET=database-mariadb; MY_PORT=3306
    MY_USER=root; MY_PASSWORD="$MARIADB_ROOT_PASSWORD"
    my_tools_detect || return 1
    echo "Restore-Werkzeuge: $MY_IMAGE"
  fi
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
    pg_tools_restore_owned "$restore_major" "$abs" "$name" "$owner" || return 1
  else
    gzip -dc "$abs" | my_tools_client "$MY_IMAGE" "$MY_CLIENT" "$name"
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
  pwd="$(openssl rand -hex 16)"
  if [[ "$eng" == postgres ]]; then
    printf "ALTER ROLE \"%s\" PASSWORD '%s';\n" "$name" "$pwd" | pg -d postgres
  else
    printf "ALTER USER '%s'@'%%' IDENTIFIED BY '%s';\n" "$name" "$pwd" | my
  fi
  sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$pwd/" "$file"
  chmod 600 "$file"
  echo "Password changed. Update application secrets using: $file"
}
# Destructive cleanup is limited to an application pair managed by this script.
# Stored backups are deliberately retained.
delete_managed() {
  local eng="$1" name="$2" cred dir stamp target tmp owner count other
  require_engine "$eng"; require_name "$name"
  cred="$CREDS/${name}-${eng}.env"
  [[ -f "$cred" && ! -L "$cred" ]] || { echo "Only managed database/user pairs can be removed (missing $cred)" >&2; return 1; }
  # Validate the managed pairing without sourcing the credential file.
  grep -Fxq "DB_NAME=$name" "$cred" && grep -Fxq "DB_USER=$name" "$cred" || {
    echo 'Credential file does not match database/user; refusing deletion.' >&2; return 1;
  }
  if [[ "$eng" == postgres ]]; then
    owner="$(pg -At -d postgres -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$name'")"
    [[ "$owner" == "$name" ]] || { echo 'Database owner differs from managed user. Refusing.' >&2; return 1; }
    count="$(pg -At -d postgres -c "SELECT count(*) FROM pg_roles WHERE rolname='$name'")"
    [[ "$count" == 1 ]] || { echo 'Role missing; refusing.' >&2; return 1; }
    other="$(pg -At -d postgres -c "SELECT count(*) FROM pg_database WHERE datdba=(SELECT oid FROM pg_roles WHERE rolname='$name') AND datname<>'$name'")"
    [[ "$other" == 0 ]] || { echo 'Role owns other databases; refusing.' >&2; return 1; }
  else
    count="$(my -N -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$name'")"
    [[ "$count" == 1 ]] || { echo 'Database missing; refusing.' >&2; return 1; }
    count="$(my -N -e "SELECT COUNT(*) FROM mysql.user WHERE User='$name' AND Host='%'")"
    [[ "$count" == 1 ]] || { echo "Managed MariaDB user '$name'@'%' missing; refusing." >&2; return 1; }
    # Reject users who have grants on other databases or global privileges.
    other="$(my -N -e "SELECT COUNT(*) FROM mysql.db WHERE User='$name' AND Db<>'$name'")"
    [[ "$other" == 0 ]] || { echo 'User has grants on other databases; refusing.' >&2; return 1; }
  fi
  echo "STOP all applications using $eng/$name before proceeding."
  echo "WARNING: database $eng/$name AND user $name will be permanently deleted."
  echo 'An archive backup will be created and verified before deletion.'
  confirm "DELETE $eng $name AND USER"
  dir="$BACKUPS/$eng"
  mkdir -p "$dir"; chmod 700 "$dir"
  stamp="$(date +%Y%m%d_%H%M%S)_before_delete_$$"
  if [[ "$eng" == postgres ]]; then
    target="$dir/${name}_${stamp}.dump"
  else
    target="$dir/${name}_${stamp}.sql.gz"
  fi
  [[ ! -e "$target" ]] || { echo "Backup already exists: $target" >&2; return 1; }
  tmp="$(mktemp "$dir/.delete-backup.XXXXXXXX")" || return 1
  if [[ "$eng" == postgres ]]; then
    if ! docker exec -u postgres database-postgres pg_dump -U postgres -Fc -d "$name" > "$tmp" ||
       ! docker exec -i -u postgres database-postgres pg_restore -l < "$tmp" > /dev/null; then
      rm -f "$tmp"; echo 'Safety backup failed. Nothing deleted.' >&2; return 1
    fi
  else
    if ! ( docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" database-mariadb mariadb-dump -uroot --single-transaction --routines --events --triggers --hex-blob "$name" | gzip > "$tmp" ) || ! gzip -t "$tmp"; then
      rm -f "$tmp"; echo 'Safety backup failed. Nothing deleted.' >&2; return 1
    fi
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; echo 'Empty safety backup. Nothing deleted.' >&2; return 1; }
  mv -- "$tmp" "$target" || return 1
  (cd "$dir" && sha256sum "$(basename "$target")" > "$(basename "$target").sha256") || return 1
  echo "Verified backup: $target"
  if [[ "$eng" == postgres ]]; then
    pg -d postgres -c "DROP DATABASE \"$name\" WITH (FORCE)"
    if ! pg -d postgres -c "DROP ROLE \"$name\""; then
      echo 'Database deleted, but role deletion failed (possibly dependencies in other databases). Credentials retained.' >&2
      return 1
    fi
  else
    my -e "DROP DATABASE \`$name\`;"
    if ! my -e "DROP USER '$name'@'%';"; then
      echo 'Database deleted, but user deletion failed. Credentials retained.' >&2
      return 1
    fi
  fi
  # Archive the credential, do not leave misleading active connection details.
  local archive="$CREDS/deleted"
  mkdir -p "$archive"; chmod 700 "$archive"
  mv -- "$cred" "$archive/${name}-${eng}-${stamp}.env"
  echo "Deleted $eng/$name and managed user $name. Backup preserved: $target"
  echo "Old credential archived under $archive"
}

menu() {
  local opt eng name file mode choice
  while true; do
    printf '\n========== SYNOLOGY DATABASE MANAGER ==========\n'
    printf '1) Status\n2) Datenbanken auflisten\n3) Datenbank + Benutzer anlegen\n4) Backup aller Dienste\n5) Einzel-Backup\n6) SQL-Restore (Backup-Auswahl)\n7) App-Passwort erneuern\n8) Valkey-Restore (Backup-Auswahl)\n9) Backups anzeigen\n10) Datenbank + zugehörigen Benutzer löschen\n11) Einzel-Backup aller Dienste\n0) Beenden\n'
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
      10) eng="$(select_engine)" || continue; [[ "$eng" != valkey ]] || { echo "Valkey does not use SQL users"; continue; }; name="$(select_db "$eng")" || continue; delete_managed "$eng" "$name" ;;
      11) backup_each || echo "Ein oder mehrere Backups fehlgeschlagen (siehe Meldungen oben)." ;;
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
 backup-each) [[ $# == 1 ]] || exit 2; backup_each ;;
 restore) [[ $# -ge 4 && $# -le 5 ]] || exit 2; restore "$2" "$3" "$4" "${5:-safe}" ;;
 restore-valkey) [[ $# == 2 ]] || exit 2; restore_valkey "$2" ;;
 rotate) [[ $# == 3 ]] || exit 2; rotate "$2" "$3" ;;
 delete) [[ $# == 3 ]] || exit 2; delete_managed "$2" "$3" ;;
 *) echo 'Usage: db-manager.sh [menu|status|list [postgres|mariadb|all]|create ENGINE NAME|backup [all|postgres|mariadb|valkey] [NAME|all]|restore ENGINE NAME FILE [safe|overwrite]|restore-valkey FILE|rotate ENGINE NAME|delete ENGINE NAME|backup-each]' >&2; exit 2 ;;
esac
