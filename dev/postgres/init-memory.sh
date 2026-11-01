#!/bin/sh
set -eu

# Create missing development resources without changing existing data or passwords.
psql --no-psqlrc --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
\getenv memory_password MEMORY_DATABASE_PASSWORD

SELECT format('CREATE ROLE ivenna_memory LOGIN PASSWORD %L', :'memory_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ivenna_memory')
\gexec

SELECT 'CREATE DATABASE ivenna_memory OWNER ivenna_memory'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ivenna_memory')
\gexec
SQL
