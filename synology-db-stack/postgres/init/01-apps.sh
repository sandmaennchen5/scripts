#!/bin/bash
set -Eeuo pipefail
: "${PAPERLESS_DB_PASSWORD:?}" "${FORGEJO_DB_PASSWORD:?}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v pwp="$PAPERLESS_DB_PASSWORD" -v pwf="$FORGEJO_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'paperlessuser', :'pwp')
 WHERE NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='paperlessuser') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', 'paperless', 'paperlessuser')
 WHERE NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='paperless') \gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'forgejo', :'pwf')
 WHERE NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='forgejo') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', 'forgejo', 'forgejo')
 WHERE NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='forgejo') \gexec
SQL
