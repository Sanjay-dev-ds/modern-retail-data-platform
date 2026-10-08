"""Sales: one transaction header with its lines and payments (pos.transactions, pos.transaction_lines,
pos.payments). Defects from config.defects are injected here so the rows reach DMS already dirty.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal

from retail_gen.entities.catalog import ORPHAN_SKU_START, SkuPicker, sku_code
from retail_gen.entities.common import money, new_uuid, poisson
from retail_gen.entities.stores import ONLINE_STORE_ID

PROMOS = {"SAVE10": Decimal("0.10"), "WEEKEND15": Decimal("0.15"), "LOYAL20": Decimal("0.20")}
PROMO_LINE_RATE = 0.15
QUANTITIES = [1, 1, 1, 1, 2, 2, 3, 4]
PAYMENT_METHODS = {
    "store": (["card", "cash", "wallet", "gift_card"], [0.6, 0.25, 0.1, 0.05]),
    "online": (["card", "wallet", "gift_card"], [0.75, 0.2, 0.05]),
}


@dataclass
class Sale:
    txn: dict
    lines: list[dict] = field(default_factory=list)
    payments: list[dict] = field(default_factory=list)


def make_sale(
    rng: random.Random,
    *,
    ts: datetime,
    store_id: int,
    customer_id: int | None,
    picker: SkuPicker,
    avg_lines: float,
    split_payment_rate: float,
    defects,
) -> Sale:
    channel = "online" if store_id == ONLINE_STORE_ID else "store"
    txn_id = new_uuid(rng)

    lines = []
    n_lines = max(1, poisson(rng, avg_lines))
    for line_no, product in enumerate(picker.pick_distinct(rng, n_lines), start=1):
        quantity = rng.choice(QUANTITIES)
        unit_price = product["list_price"]
        sku = product["sku"]
        if rng.random() < defects.orphan_sku:
            sku = sku_code(ORPHAN_SKU_START + rng.randint(0, 9999))  # not in any catalog file
        promo_code, discount = None, Decimal("0")
        if rng.random() < PROMO_LINE_RATE:
            promo_code = rng.choice(list(PROMOS))
            discount = money(quantity * unit_price * PROMOS[promo_code])
        lines.append({
            "transaction_id": txn_id,
            "line_no": line_no,
            "sku": sku,
            "quantity": quantity,
            "unit_price": unit_price,
            "discount_amount": discount,
            "promo_code": promo_code,
        })

    if rng.random() < defects.invalid_values:
        bad = rng.choice(lines)
        if rng.random() < 0.5:
            bad["quantity"] = rng.choice([0, -1])
        else:
            bad["unit_price"] = Decimal("0.00")

    total = money(sum(l["quantity"] * l["unit_price"] - l["discount_amount"] for l in lines))

    txn = {
        "transaction_id": txn_id,
        "store_id": store_id,
        "customer_id": customer_id,
        "channel": channel,
        "txn_ts": ts,
        "status": "completed",
        "total_amount": total,
        "currency": "USD",
        "created_at": ts,
        "updated_at": ts,
    }
    return Sale(txn, lines, _payments(rng, txn, split_payment_rate, defects))


def _payments(rng: random.Random, txn: dict, split_rate: float, defects) -> list[dict]:
    total = txn["total_amount"]
    methods, weights = PAYMENT_METHODS[txn["channel"]]
    if total > Decimal("10") and rng.random() < split_rate:
        # Split tender: part on a gift card, the rest on card. Two rows for one transaction.
        gift = money(total * Decimal(str(rng.uniform(0.2, 0.6))))
        parts = [("gift_card", gift), ("card", total - gift)]
    else:
        parts = [(rng.choices(methods, weights)[0], total)]

    if rng.random() < defects.payment_mismatch:
        method, amount = parts[-1]
        parts[-1] = (method, amount + money(rng.choice([-1, 1]) * rng.uniform(0.01, 5.0)))

    return [
        {
            "payment_id": new_uuid(rng),
            "transaction_id": txn["transaction_id"],
            "method": method,
            "amount": amount,
            "created_at": txn["txn_ts"],
        }
        for method, amount in parts
    ]
