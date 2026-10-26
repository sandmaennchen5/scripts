#!/usr/bin/env bash
# Ephemeral MariaDB/MySQL clients; no server or volumes are started.
my_tools_client() {
  local image="$1" tool="$2"; shift 2
  local host="$MY_TARGET"
  local -a network=(--network host)
  if [[ "$MY_KIND" == docker ]]; then network=(--network "container:$MY_TARGET"); host=127.0.0.1; fi
  MYSQL_PWD="$MY_PASSWORD" docker run --rm -i "${network[@]}" -e MYSQL_PWD --entrypoint "$tool" "$image" --connect-timeout=10 -h "$host" -P "$MY_PORT" -u "$MY_USER" --protocol=tcp "$@"
}
my_tools_detect() {
  local version numeric
  version="$(my_tools_client "${MARIADB_BOOTSTRAP_IMAGE:-mariadb:11.8}" mariadb -N -B -e "SELECT CONCAT(VERSION(), ' ', @@version_comment)")" || return 1
  numeric="${version#5.5.5-}"
  [[ "$numeric" =~ ^([0-9]+).([0-9]+). ]] || { echo "Cannot detect MariaDB/MySQL version" >&2; return 1; }
  MY_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  if [[ "${version,,}" == *mariadb* ]]; then
    MY_IMAGE="mariadb:$MY_VERSION"; MY_CLIENT=mariadb; MY_DUMP=mariadb-dump
  else
    MY_IMAGE="mysql:$MY_VERSION"; MY_CLIENT=mysql; MY_DUMP=mysqldump
  fi
}
