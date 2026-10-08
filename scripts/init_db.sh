#!/usr/bin/env bash
# Run on the platform host (any shell, any directory). Creates the POS schema in RDS.
# DB_SECRET_ID comes from /etc/retail/platform.env; the credentials from Secrets Manager.
set -euo pipefail

set -a; source /etc/retail/platform.env; set +a
SCHEMA_FILE="${1:-$(dirname "$0")/../sql/pos/01_schema.sql}"

SECRET=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ID" --query SecretString --output text)

export PGHOST=$(jq -r .host <<<"$SECRET")
export PGPORT=$(jq -r .port <<<"$SECRET")
export PGDATABASE=$(jq -r .dbname <<<"$SECRET")
export PGUSER=$(jq -r .username <<<"$SECRET")
export PGPASSWORD=$(jq -r .password <<<"$SECRET")
export PGSSLMODE=require

psql -v ON_ERROR_STOP=1 -f "$SCHEMA_FILE"
psql -c "SHOW rds.logical_replication;"
