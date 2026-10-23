#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE"
[ ! -e .env ] || { echo '.env already exists; refusing to overwrite' >&2; exit 1; }
cp .env.example .env
for name in POSTGRES_ADMIN_PASSWORD MARIADB_ROOT_PASSWORD PAPERLESS_DB_PASSWORD FORGEJO_DB_PASSWORD ROMM_DB_PASSWORD GAME_DB_PASSWORD VALKEY_PASSWORD; do
  value="$(openssl rand -hex 32)"
  sed -i "s/^${name}=CHANGE_ME$/${name}=${value}/" .env
done
chmod 600 .env
chmod 700 credentials backups
chmod 644 postgres/init/*.sh mariadb/init/*.sh
printf 'Created .env with distinct 64-character hex passwords.\nKeep a protected copy outside this NAS.\n'
