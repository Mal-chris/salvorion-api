#!/usr/bin/env bash
# Runs once on first start of the postgres container (empty data volume).
# Prepares the source database for PowerSync logical replication and creates
# the bucket-storage database. See https://docs.powersync.com/self-hosting/appendix/database-connection
set -euo pipefail

: "${POWERSYNC_DB_USER:=powersync}"
: "${POWERSYNC_DB_PASSWORD:=powersync}"
: "${POWERSYNC_STORAGE_DB:=powersync_storage}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
  -- Replication role used by the PowerSync service. BYPASSRLS is required by
  -- PowerSync so replication is not filtered by row-level security policies.
  CREATE ROLE "${POWERSYNC_DB_USER}" WITH REPLICATION BYPASSRLS LOGIN PASSWORD '${POWERSYNC_DB_PASSWORD}';

  -- Read-only access to every current and future table in public.
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO "${POWERSYNC_DB_USER}";
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO "${POWERSYNC_DB_USER}";

  -- PowerSync requires the publication to be named exactly "powersync".
  CREATE PUBLICATION powersync FOR ALL TABLES;

  -- Separate database for PowerSync's sync-bucket storage.
  CREATE DATABASE "${POWERSYNC_STORAGE_DB}";
SQL
