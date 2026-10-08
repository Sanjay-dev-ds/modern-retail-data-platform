"""PostgreSQL connection and bulk load helpers."""

from __future__ import annotations

import json
from collections.abc import Iterable, Sequence

import boto3
import psycopg


def connect(db_secret_id: str) -> psycopg.Connection:
    """Connect with the credentials in the DB secret written by Terraform (rds.tf)."""
    secret = json.loads(
        boto3.client("secretsmanager").get_secret_value(SecretId=db_secret_id)["SecretString"]
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
