"""Stores (pos.stores). store_id 0 is the online shop."""

from __future__ import annotations

import random
from datetime import date, datetime, timedelta

from faker import Faker

ONLINE_STORE_ID = 0
REGIONS = ["north", "south", "east", "west"]
FORMATS = ["hyper", "express", "outlet"]


def make_stores(rng: random.Random, fake: Faker, n: int, now: datetime) -> list[dict]:
    online = {
        "store_id": ONLINE_STORE_ID,
        "store_name": "Online",
        "region": "online",
        "format": "online",
        "open_date": date(2018, 1, 1),
        "updated_at": now,
    }
    stores = [online]
    for store_id in range(1, n + 1):
        fmt = rng.choice(FORMATS)
        stores.append({
            "store_id": store_id,
            "store_name": f"{fake.city()} {fmt.title()}",
            "region": rng.choice(REGIONS),
            "format": fmt,
            "open_date": (now - timedelta(days=rng.randint(365, 365 * 15))).date(),
            "updated_at": now,
        })
    return stores


def store_change(rng: random.Random) -> dict:
    """A rare attribute change on a physical store (feeds the SCD2 store dimension)."""
    if rng.random() < 0.7:
        return {"format": rng.choice(FORMATS)}
    return {"region": rng.choice(REGIONS)}
