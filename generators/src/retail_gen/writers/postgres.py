"""PostgreSQL connection and bulk load helpers.

Credentials come from the Secrets Manager secret named by DB_SECRET_ID, which the platform
host loads from /etc/airflow/infra.env (written by Terraform) in login shells.
"""

from __future__ import annotations

import json
import os
from collections.abc import Iterable, Sequence

import boto3
import psycopg


def connect() -> psycopg.Connection:
    secret_id = os.environ.get("DB_SECRET_ID")
    if not secret_id:
        raise SystemExit("DB_SECRET_ID is not set (run on the platform host, in a login shell)")

    secret = json.loads(
        boto3.client("secretsmanager").get_secret_value(SecretId=secret_id)["SecretString"]
    )
    return psycopg.connect(
        host=secret["host"],
        port=secret["port"],
        dbname=secret["dbname"],
        user=secret["username"],
        password=secret["password"],
        sslmode="require",
    )


def copy_rows(conn: psycopg.Connection, table: str, columns: Sequence[str], rows: Iterable[dict]) -> int:
    """COPY dict rows into table. Fast enough for both the seed and incremental batches."""
    count = 0
    with conn.cursor() as cur:
        with cur.copy(f"COPY {table} ({', '.join(columns)}) FROM STDIN") as copy:
            for row in rows:
                copy.write_row([row[c] for c in columns])
                count += 1
    return count
