"""Loyalty customers (pos.customers). Emails use example.com so no real address is ever generated."""

from __future__ import annotations

import random
from datetime import datetime, timedelta

from faker import Faker

TIERS = ["bronze", "silver", "gold"]
TIER_WEIGHTS = [0.7, 0.22, 0.08]


def make_customers(
    rng: random.Random,
    fake: Faker,
    n: int,
    home_store_ids: list[int],
    signup_before: datetime,
    null_rate: float,
) -> list[dict]:
    customers = []
    for customer_id in range(1, n + 1):
        first, last = fake.first_name(), fake.last_name()
        email = f"{first}.{last}{customer_id}@example.com".lower()
        if rng.random() < null_rate:
            email = None  # defect: sign-up without email
        customers.append({
            "customer_id": customer_id,
            "email": email,
            "phone": f"+1-555-{rng.randint(100, 999)}-{rng.randint(1000, 9999)}",
            "loyalty_tier": rng.choices(TIERS, TIER_WEIGHTS)[0],
            "home_store_id": rng.choice(home_store_ids),
            "signup_at": signup_before - timedelta(days=rng.uniform(1, 730)),
            "updated_at": signup_before,
        })
    return customers


def customer_change(rng: random.Random, current_tier: str, email: str | None, customer_id: int) -> dict:
    """Tier upgrade (SCD2), or a fix for a missing email."""
    if email is None and rng.random() < 0.5:
        return {"email": f"customer{customer_id}@example.com"}
    idx = TIERS.index(current_tier)
    if idx < len(TIERS) - 1:
        return {"loyalty_tier": TIERS[idx + 1]}
    return {"loyalty_tier": TIERS[idx - 1]}  # gold members who lapse
