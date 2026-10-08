#!/usr/bin/env bash
# Run on the generator host. Creates the POS schema in RDS.
# Requires DB_SECRET_ID (set by /etc/profile.d/retail.sh), aws cli, jq, psql.
set -euo pipefail

: "${DB_SECRET_ID:?DB_SECRET_ID is not set}"
SCHEMA_FILE="${1:-sql/pos/01_schema.sql}"

SECRET=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ID" \
  --query SecretString --output text)

export PGHOST=$(jq -r .host <<<"$SECRET")
export PGPORT=$(jq -r .port <<<"$SECRET")
export PGDATABASE=$(jq -r .dbname <<<"$SECRET")
export PGUSER=$(jq -r .username <<<"$SECRET")
export PGPASSWORD=$(jq -r .password <<<"$SECRET")
export PGSSLMODE=require

psql -v ON_ERROR_STOP=1 -f "$SCHEMA_FILE"
psql -c "SHOW rds.logical_replication;"
