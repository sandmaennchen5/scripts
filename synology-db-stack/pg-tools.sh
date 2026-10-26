#!/usr/bin/env bash
# Shared ephemeral PostgreSQL clients; Docker pulls missing images automatically.
pg_tools_run() {
  local major="$1" tool="$2"; shift 2
  [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 10)) || { echo "Unsupported PostgreSQL major version" >&2; return 1; }
  local -a network=(--network host)
  [[ "$PG_KIND" != docker ]] || network=(--network "container:$PG_TARGET")
  PGPASSWORD="$PG_PASSWORD" PGCONNECT_TIMEOUT=10 docker run --rm -i "${network[@]}" -e PGPASSWORD -e PGCONNECT_TIMEOUT --entrypoint "$tool" "postgres:$major" "$@"
}
pg_tools_client() {
  local major="$1" tool="$2"; shift 2
  local host="$PG_TARGET"
  [[ "$PG_KIND" != docker ]] || host=127.0.0.1
  pg_tools_run "$major" "$tool" -h "$host" -p "$PG_PORT" -U "$PG_USER" "$@"
}
pg_tools_major() {
  local version
  version="$(pg_tools_client "${PG_BOOTSTRAP_MAJOR:-18}" psql -X -At -v ON_ERROR_STOP=1 -d "$1" -c "SHOW server_version_num")" || return 1
  [[ "$version" =~ ^[0-9]+$ ]] || { echo "Cannot detect PostgreSQL server version" >&2; return 1; }
  printf "%s\n" "$((version / 10000))"
}
pg_tools_restore_major() {
  local file="$1" target="$2" listing dumped major
  # Inspect archive before any destructive action; also works without metadata.
  listing="$(pg_tools_run "${PG_BOOTSTRAP_MAJOR:-18}" pg_restore --list < "$file")" || return 1
  dumped="$(printf '%s\n' "$listing" | sed -n 's/^;[[:space:]]*Dumped by pg_dump version: //p')"
  major="${dumped%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 10)) || { echo "Cannot detect dump tool version" >&2; return 1; }
  ((target >= major)) || { echo "Restore aborted: dump requires PostgreSQL $major or newer; target is $target." >&2; return 1; }
  pg_tools_run "$major" pg_restore --list < "$file" >/dev/null || return 1
  printf "%s\n" "$major"
}

# Stream the TOC and archive via stdin; large catalogs never enter argv/environment.
pg_tools_restore_list() {
  local major="$1" listing="$2"; shift 2
  local host="$PG_TARGET" LC_ALL=C
  [[ "$PG_KIND" != docker ]] || host=127.0.0.1
  # Drain the archive after pg_restore exits: extension-only restores may stop
  # reading early, otherwise the producer fails with SIGPIPE under pipefail.
  {
    printf "%s\n" "${#listing}"
    printf "%s" "$listing"
    cat
  } | pg_tools_run "$major" sh -c 'IFS= read -r size || exit 1; head -c "$size" > /tmp/restore.list || exit 1; pg_restore --use-list=/tmp/restore.list "$@"; result=$?; cat >/dev/null; exit "$result"' sh -h "$host" -p "$PG_PORT" -U "$PG_USER" "$@"
}

# Use a dedicated NOLOGIN role so privileged dump objects can be restored,
 # then transfer only objects created by this restore (never all postgres objects).
pg_tools_restore_owned() (
  local major="$1" file="$2" database="$3" owner="$4"
  local restore_role="dbrestore_${BASHPID}_${RANDOM}"
  local owner_quoted="${owner//\"/\"\"}"
  cleanup_restore_role() {
    pg_tools_client "$major" psql -X -v ON_ERROR_STOP=1 -d "$database" -c "ALTER ROLE \"$restore_role\" NOSUPERUSER" >/dev/null || {
      echo "ERROR: Could not revoke temporary role privileges: $restore_role" >&2; return 1;
    }
    pg_tools_client "$major" psql -X -v ON_ERROR_STOP=1 -d "$database" -c "DROP ROLE \"$restore_role\"" >/dev/null || {
      echo "ERROR: Temporary NOLOGIN role still owns objects: $restore_role" >&2; return 1;
    }
  }
  pg_tools_client "$major" psql -X -v ON_ERROR_STOP=1 -d "$database" -c "CREATE ROLE \"$restore_role\" NOLOGIN SUPERUSER" >/dev/null || return 1
  trap 'cleanup_restore_role' EXIT
  echo "Restoring archive with temporary NOLOGIN administrator role..." >&2
  pg_tools_client "$major" pg_restore --role="$restore_role" --no-owner --no-privileges --exit-on-error --single-transaction -d "$database" < "$file" || return 1
  pg_tools_client "$major" psql -X -v ON_ERROR_STOP=1 -d "$database" -c "REASSIGN OWNED BY \"$restore_role\" TO \"$owner_quoted\"" >/dev/null || return 1
  cleanup_restore_role || return 1
  trap - EXIT
)
