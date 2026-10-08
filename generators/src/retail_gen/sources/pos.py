"""Source A: the POS database. Inserts and changes here are what DMS replicates to S3."""

from __future__ import annotations

import random
from datetime import datetime, timedelta

import psycopg

from retail_gen.entities.common import new_uuid
from retail_gen.entities.customers import customer_change
from retail_gen.entities.stores import ONLINE_STORE_ID, store_change
from retail_gen.entities.transactions import Sale
from retail_gen.writers.postgres import copy_rows

COLUMNS = {
    "pos.stores": ["store_id", "store_name", "region", "format", "open_date", "updated_at"],
    "pos.customers": ["customer_id", "email", "phone", "loyalty_tier", "home_store_id", "signup_at", "updated_at"],
    "pos.transactions": [
        "transaction_id", "store_id", "customer_id", "channel", "txn_ts", "status",
        "total_amount", "currency", "created_at", "updated_at",
    ],
    "pos.transaction_lines": [
        "transaction_id", "line_no", "sku", "quantity", "unit_price", "discount_amount", "promo_code",
    ],
    "pos.payments": ["payment_id", "transaction_id", "method", "amount", "created_at"],
}


def is_seeded(conn: psycopg.Connection) -> bool:
    return conn.execute("SELECT EXISTS (SELECT 1 FROM pos.stores)").fetchone()[0]


def truncate_all(conn: psycopg.Connection) -> None:
    # Only before DMS starts: DMS does not replicate TRUNCATE to the S3 target.
    conn.execute("TRUNCATE pos.payments, pos.transaction_lines, pos.transactions, pos.customers, pos.stores")


def insert_rows(conn: psycopg.Connection, table: str, rows: list[dict]) -> int:
    return copy_rows(conn, table, COLUMNS[table], rows)


def insert_sales(conn: psycopg.Connection, sales: list[Sale]) -> None:
    # Parent before child, so the foreign keys hold.
    insert_rows(conn, "pos.transactions", [s.txn for s in sales])
    insert_rows(conn, "pos.transaction_lines", [l for s in sales for l in s.lines])
    insert_rows(conn, "pos.payments", [p for s in sales for p in s.payments])


def reference_ids(conn: psycopg.Connection) -> tuple[list[int], list[int]]:
    """Physical store ids and customer ids currently in the database."""
    stores = [r[0] for r in conn.execute(
        "SELECT store_id FROM pos.stores WHERE store_id <> %s ORDER BY 1", (ONLINE_STORE_ID,))]
    customers = [r[0] for r in conn.execute("SELECT customer_id FROM pos.customers ORDER BY 1")]
    return stores, customers


# ---------------------------------------------------------------- changes (CDC updates/deletes)

def void_recent(conn: psycopg.Connection, n: int, now: datetime) -> list:
    """Cashier voids: completed sales from the last hour become 'voided'. Returns their ids."""
    if n <= 0:
        return []
    return [r[0] for r in conn.execute(
        """
        UPDATE pos.transactions SET status = 'voided', updated_at = %(now)s
        WHERE transaction_id IN (
          SELECT transaction_id FROM pos.transactions
          WHERE status = 'completed' AND txn_ts > %(now)s - interval '1 hour'
          ORDER BY random() LIMIT %(n)s)
        RETURNING transaction_id
        """,
        {"now": now, "n": n},
    )]


def return_older(conn: psycopg.Connection, n: int, now: datetime) -> list:
    """Customer returns: completed sales from 1-30 days ago become 'returned'. Returns their ids."""
    if n <= 0:
        return []
    return [r[0] for r in conn.execute(
        """
        UPDATE pos.transactions SET status = 'returned', updated_at = %(now)s
        WHERE transaction_id IN (
          SELECT transaction_id FROM pos.transactions
          WHERE status = 'completed'
            AND txn_ts BETWEEN %(now)s - interval '30 days' AND %(now)s - interval '1 day'
          ORDER BY random() LIMIT %(n)s)
        RETURNING transaction_id
        """,
        {"now": now, "n": n},
    )]


def refund_payments(conn: psycopg.Connection, transaction_ids: list, now: datetime) -> int:
    """Refund voided/returned sales: one negative payment per original tender (same method),
    so a split-tender sale gets two refund rows. Inserts -> DMS Op = I on pos.payments."""
    if not transaction_ids:
        return 0
    return conn.execute(
        """
        INSERT INTO pos.payments (payment_id, transaction_id, method, amount, created_at)
        SELECT gen_random_uuid(), transaction_id, method, -amount, %(now)s
        FROM pos.payments
        WHERE transaction_id = ANY(%(ids)s) AND amount > 0
        """,
        {"ids": transaction_ids, "now": now},
    ).rowcount


def delete_test_transactions(conn: psycopg.Connection, n: int) -> int:
    """Hard deletes (cleanup of 'test' sales), so DMS emits Op='D' rows for all three tables."""
    if n <= 0:
        return 0
    ids = [r[0] for r in conn.execute(
        "SELECT transaction_id FROM pos.transactions ORDER BY random() LIMIT %s", (n,))]
    for table in ("pos.payments", "pos.transaction_lines", "pos.transactions"):
        conn.execute(f"DELETE FROM {table} WHERE transaction_id = ANY(%s)", (ids,))
    return len(ids)


def change_stores(conn: psycopg.Connection, rng: random.Random, n: int, now: datetime) -> int:
    if n <= 0:
        return 0
    rows = conn.execute(
        "SELECT store_id FROM pos.stores WHERE store_id <> %s ORDER BY random() LIMIT %s",
        (ONLINE_STORE_ID, n),
    ).fetchall()
    for (store_id,) in rows:
        _update(conn, "pos.stores", "store_id", store_id, store_change(rng), now)
    return len(rows)


def change_customers(conn: psycopg.Connection, rng: random.Random, n: int, now: datetime) -> int:
    if n <= 0:
        return 0
    rows = conn.execute(
        "SELECT customer_id, loyalty_tier, email FROM pos.customers ORDER BY random() LIMIT %s", (n,)
    ).fetchall()
    for customer_id, tier, email in rows:
        _update(conn, "pos.customers", "customer_id", customer_id,
                customer_change(rng, tier, email, customer_id), now)
    return len(rows)


_UPDATABLE = {"format", "region", "loyalty_tier", "email"}


def _update(conn: psycopg.Connection, table: str, key: str, key_value, changes: dict, now: datetime) -> None:
    assert set(changes) <= _UPDATABLE, changes  # column names are interpolated below
    sets = ", ".join(f"{col} = %s" for col in changes)
    conn.execute(
        f"UPDATE {table} SET {sets}, updated_at = %s WHERE {key} = %s",
        [*changes.values(), now, key_value],
    )


def backdate_status(rng: random.Random, sale: Sale, void_rate: float, return_rate: float, now: datetime) -> None:
    """History rows: apply the void/return (and its refund) the sale would have had by now."""
    ts = sale.txn["txn_ts"]
    r = rng.random()
    if r < void_rate:
        changed_at = ts + timedelta(minutes=rng.uniform(1, 15))
        sale.txn["status"] = "voided"
    elif r < void_rate + return_rate and ts + timedelta(days=10) < now:
        changed_at = ts + timedelta(days=rng.uniform(1, 10))
        sale.txn["status"] = "returned"
    else:
        return
    sale.txn["updated_at"] = changed_at
    sale.payments += [
        {**p, "payment_id": new_uuid(rng), "amount": -p["amount"], "created_at": changed_at}
        for p in sale.payments
    ]
