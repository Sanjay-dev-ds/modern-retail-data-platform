# Airflow + Cosmos (renders dbt models as Airflow tasks) + dbt-snowflake in its own venv,
# so dbt's dependencies never clash with Airflow's. Built by `docker compose up -d --build`.
ARG AIRFLOW_VERSION=3.3.2
FROM apache/airflow:${AIRFLOW_VERSION}
ARG AIRFLOW_VERSION

# Pin apache-airflow so pip never up/downgrades it while adding Cosmos.
RUN pip install --no-cache-dir "apache-airflow==${AIRFLOW_VERSION}" "astronomer-cosmos==1.15.1"

RUN python -m venv /home/airflow/dbt_venv \
 && /home/airflow/dbt_venv/bin/pip install --no-cache-dir "dbt-snowflake==1.12.1"
