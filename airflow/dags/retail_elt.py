"""Hourly ELT: S3 landing files -> Snowflake RAW (COPY INTO) -> dbt models (Cosmos).

load_raw  One COPY INTO per source. Snowflake keeps 64 days of load history per table, so
          files already loaded are skipped: re-running is safe and only new files are loaded.
dbt       Cosmos turns every dbt model into its own task, followed by that model's tests, plus
          source freshness checks. Profile comes from the snowflake_default connection.
"""

from __future__ import annotations

import pendulum
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.sdk import DAG, TaskGroup
from cosmos import DbtTaskGroup, ExecutionConfig, ProfileConfig, ProjectConfig, RenderConfig
from cosmos.constants import SourceRenderingBehavior, TestBehavior, TestIndirectSelection
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

SNOWFLAKE_CONN = "snowflake_default"
DBT_PROJECT = "/opt/airflow/dbt/retail"
DBT_EXECUTABLE = "/home/airflow/dbt_venv/bin/dbt"

# DMS writes pos/pos/<table>/ (full load) and pos/pos/<table>/YYYYMMDD/ (CDC); pos_stage points
# at pos/pos/, so each table's prefix picks up both. Parquet/JSON rows land whole as VARIANT.
POS_TABLES = ["stores", "customers", "transactions", "transaction_lines", "payments"]
COPY_VARIANT = """
COPY INTO raw.{table} (record, _file, _loaded_at)
FROM (SELECT $1, METADATA$FILENAME, CURRENT_TIMESTAMP() FROM @raw.{stage})
"""
LOADS = {
    **{f"pos_{t}": COPY_VARIANT.format(table=f"pos_{t}", stage=f"pos_stage/{t}/") for t in POS_TABLES},
    "clickstream_events": COPY_VARIANT.format(table="clickstream_events", stage="clickstream_stage"),
    # CSV by column name: handles the supplier adding/reordering columns (schema drift).
    "catalog_products": """
COPY INTO raw.catalog_products
FROM @raw.catalog_stage
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (_file = METADATA$FILENAME, _loaded_at = METADATA$START_SCAN_TIME)
""",
}

with DAG(
    dag_id="retail_elt",
    schedule="@hourly",
    start_date=pendulum.datetime(2026, 10, 1, tz="UTC"),
    catchup=False,
    max_active_runs=1,
    default_args={"retries": 1, "retry_delay": pendulum.duration(minutes=2)},
    tags=["snowflake", "dbt"],
    doc_md=__doc__,
) as dag:
    with TaskGroup("load_raw") as load_raw:
        for name, sql in LOADS.items():
            SQLExecuteQueryOperator(task_id=f"copy_{name}", conn_id=SNOWFLAKE_CONN, sql=sql)

    dbt = DbtTaskGroup(
        group_id="dbt",
        project_config=ProjectConfig(DBT_PROJECT),
        profile_config=ProfileConfig(
            profile_name="retail",
            target_name="dev",
            profile_mapping=SnowflakePrivateKeyPemProfileMapping(conn_id=SNOWFLAKE_CONN),
        ),
        execution_config=ExecutionConfig(
            dbt_executable_path=DBT_EXECUTABLE,
            # A test that spans two models runs with the model whose other parent is upstream:
            # relationships fct_sales_lines.sku -> dim_product runs with fct_sales_lines, so
            # dim_product's test task only runs dimension tests.
            test_indirect_selection=TestIndirectSelection.BUILDABLE,
        ),
        render_config=RenderConfig(
            test_behavior=TestBehavior.AFTER_EACH,
            source_rendering_behavior=SourceRenderingBehavior.WITH_TESTS_OR_FRESHNESS,
        ),
        operator_args={"install_deps": True},
    )

    load_raw >> dbt
