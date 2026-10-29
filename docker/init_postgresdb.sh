#!/bin/bash
set -e

# POSTGRES_USER, POSTGRES_DB, and POSTGRES_PASSWORD come from the postgres image.
# CDR_DB_NAME, CDR_USER, and CDR_PASSWORD are set by docker-compose for Smile CDR.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
   CREATE ROLE $CDR_USER LOGIN PASSWORD '$CDR_PASSWORD';
   CREATE DATABASE $CDR_DB_NAME;
EOSQL

# Postgres 15+ requires explicit grants on the public schema.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$CDR_DB_NAME" <<-EOSQL
    GRANT ALL PRIVILEGES ON DATABASE $CDR_DB_NAME TO $CDR_USER;
    GRANT ALL PRIVILEGES ON SCHEMA public TO $CDR_USER;
EOSQL
