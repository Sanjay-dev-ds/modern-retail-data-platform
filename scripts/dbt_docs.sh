#!/usr/bin/env bash
# Generate and serve the dbt docs (lineage, model/column descriptions, tests) from the EC2 host.
#   On the host, as root:   bash /opt/retail/scripts/dbt_docs.sh
#   On your laptop:         make dbt-docs   -> http://localhost:8081
# Ctrl+C stops the server. Runs in a one-off container from the Airflow image (which has dbt).
set -euo pipefail

set -a; source /etc/retail/platform.env; set +a
CONN=$(aws secretsmanager get-secret-value --secret-id "$SECRETS_PREFIX/connections/snowflake_default" \
  --query SecretString --output text)
export SNOWFLAKE_ACCOUNT=$(jq -r '.extra | fromjson | .account' <<<"$CONN")
export SNOWFLAKE_PRIVATE_KEY=$(jq -r '.extra | fromjson | .private_key_content' <<<"$CONN")

cd /opt/retail/airflow
# The dbt project is mounted read-only, so work on a copy in /tmp inside the container.
docker compose run --rm --no-deps -p 127.0.0.1:8081:8081 \
  -e SNOWFLAKE_ACCOUNT -e SNOWFLAKE_PRIVATE_KEY \
  --entrypoint bash airflow-scheduler -c '
    set -e
    cp -r /opt/airflow/dbt/retail /tmp/retail && cd /tmp/retail
    DBT=/home/airflow/dbt_venv/bin/dbt
    $DBT deps --profiles-dir .
    $DBT docs generate --profiles-dir .
    echo "dbt docs: run \"make dbt-docs\" on your laptop, then open http://localhost:8081"
    $DBT docs serve --profiles-dir . --host 0.0.0.0 --port 8081 --no-browser'
