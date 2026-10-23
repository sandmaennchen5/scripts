#!/bin/bash
set -Eeuo pipefail
: "${ROMM_DB_PASSWORD:?}" "${GAME_DB_PASSWORD:?}"
for pwd in "$ROMM_DB_PASSWORD" "$GAME_DB_PASSWORD"; do
  [[ "$pwd" =~ ^[[:xdigit:]]{64}$ ]] || { echo 'Passwords must be 64 hex chars' >&2; exit 1; }
done
docker_process_sql <<SQL
CREATE DATABASE IF NOT EXISTS romm CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'romm'@'%' IDENTIFIED BY '${ROMM_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON romm.* TO 'romm'@'%';
CREATE DATABASE IF NOT EXISTS game CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'gameuser'@'%' IDENTIFIED BY '${GAME_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON game.* TO 'gameuser'@'%';
SQL
