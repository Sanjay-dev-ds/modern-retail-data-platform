"""Source C: the supplier's daily catalog snapshot, uploaded as CSV.

The latest file is the only state: each day's snapshot is derived from the previous one.
"""

from __future__ import annotations

from datetime import date, datetime

from retail_gen.entities.catalog import from_csv, to_csv
from retail_gen.writers.objects import ObjectStore

PREFIX = "catalog/products/"


def snapshot_key(as_of: datetime) -> str:
    return f"{PREFIX}dt={as_of:%Y-%m-%d}/products_{as_of:%Y%m%d%H%M%S}.csv"


def publish(store: ObjectStore, products: list[dict], as_of: datetime, drift_day: date | None) -> str:
    key = snapshot_key(as_of)
    store.put_text(key, to_csv(products, as_of.date(), drift_day))
    return key


def latest(store: ObjectStore) -> tuple[date, list[dict]] | None:
    """Most recent snapshot. Keys sort chronologically (dt=, then the timestamp in the name)."""
    keys = [k for k in store.list_keys(PREFIX) if k.endswith(".csv")]
    if not keys:
        return None
    key = max(keys)
    day = date.fromisoformat(key[len(PREFIX) + 3 : len(PREFIX) + 13])
    return day, from_csv(store.get_text(key))


def has_snapshot_for(store: ObjectStore, day: date) -> bool:
    return bool(store.list_keys(f"{PREFIX}dt={day:%Y-%m-%d}/"))
