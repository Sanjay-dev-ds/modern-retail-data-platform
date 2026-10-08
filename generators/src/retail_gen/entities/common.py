"""Small helpers shared by the entity builders."""

from __future__ import annotations

import math
import random
import uuid
from datetime import datetime
from decimal import ROUND_HALF_UP, Decimal

CENT = Decimal("0.01")

# Relative sales volume by UTC hour (mean 1.0). Stores trade 08-22; online peaks in the evening.
STORE_HOURLY = [0, 0, 0, 0, 0, 0, 0, 0.3, 0.8, 1.1, 1.3, 1.6, 2.0, 1.8, 1.5, 1.5, 1.8, 2.3, 2.5, 2.1, 1.6, 1.0, 0.4, 0]
ONLINE_HOURLY = [0.5, 0.3, 0.2, 0.2, 0.2, 0.3, 0.5, 0.8, 1.0, 1.0, 1.0, 1.1, 1.2, 1.1, 1.0, 1.0, 1.1, 1.3, 1.5, 1.8, 2.0, 2.0, 1.6, 1.0]
_store_mean = sum(STORE_HOURLY) / 24
_online_mean = sum(ONLINE_HOURLY) / 24
STORE_HOURLY = [w / _store_mean for w in STORE_HOURLY]
ONLINE_HOURLY = [w / _online_mean for w in ONLINE_HOURLY]

# Weekend uplift: Monday=0 ... Sunday=6
WEEKDAY_FACTOR = [0.9, 0.9, 0.95, 1.0, 1.1, 1.3, 1.2]


def money(value: float | Decimal) -> Decimal:
    return Decimal(str(value)).quantize(CENT, rounding=ROUND_HALF_UP)


def new_uuid(rng: random.Random) -> uuid.UUID:
    """Deterministic UUID4 drawn from rng (so a seeded run is reproducible)."""
    return uuid.UUID(int=rng.getrandbits(128), version=4)


def poisson(rng: random.Random, lam: float) -> int:
    """Poisson sample; normal approximation for large means."""
    if lam <= 0:
        return 0
    if lam > 50:
        return max(0, round(rng.gauss(lam, math.sqrt(lam))))
    limit, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= rng.random()
        if p <= limit:
            return k
        k += 1


def iso_utc(ts: datetime) -> str:
    """ISO-8601 UTC with millisecond precision, e.g. 2026-10-08T14:03:07.123Z."""
    return ts.strftime("%Y-%m-%dT%H:%M:%S.") + f"{ts.microsecond // 1000:03d}Z"
