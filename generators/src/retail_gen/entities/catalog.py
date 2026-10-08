"""Product catalog: the supplier's daily full snapshot (source C).

A product is a plain dict keyed by the CSV columns. The catalog's only state is the latest
snapshot file, so everything needed to evolve it is in the CSV itself.
"""

from __future__ import annotations

import bisect
import csv
import io
import random
import zlib
from datetime import UTC, date, datetime
from decimal import Decimal

from retail_gen.entities.common import money

COLUMNS = [
    "sku", "product_name", "brand", "category", "subcategory",
    "unit_cost", "list_price", "is_active", "supplier_updated_at",
]
DRIFT_COLUMN = "pack_size"  # appears from config.defects.schema_drift_day onward

CATEGORIES = {
    "grocery": (["snacks", "beverages", "dairy", "bakery", "pantry"], (1.5, 15.0)),
    "household": (["cleaning", "paper_goods", "laundry"], (3.0, 30.0)),
    "personal_care": (["skincare", "haircare", "oral_care"], (3.0, 40.0)),
    "electronics": (["audio", "accessories", "smart_home"], (15.0, 250.0)),
    "apparel": (["mens", "womens", "kids"], (10.0, 90.0)),
}
BRANDS = ["Northwind", "Bluebird", "Acme", "Evergreen", "Summit", "Harbor", "Maple & Co", "Brightline", "Oakridge", "Nimbus"]
VARIANTS = ["Classic", "Original", "Premium", "Lite", "Max", "Mini", "Family Size", "Organic", "Select", "Plus"]
PACK_SIZES = ["1", "2-pack", "4-pack", "6-pack", "12 x 330ml", "500g", "1kg"]
ORPHAN_SKU_START = 90000  # real SKUs stay below this; orphan-SKU defects use 9xxxx


def sku_code(n: int) -> str:
    return f"SKU-{n:05d}"


def _new_product(rng: random.Random, n: int, as_of: datetime) -> dict:
    category = rng.choice(list(CATEGORIES))
    subcategories, (low, high) = CATEGORIES[category]
    subcategory = rng.choice(subcategories)
    brand = rng.choice(BRANDS)
    list_price = money(rng.uniform(low, high))
    return {
        "sku": sku_code(n),
        "product_name": f"{brand} {subcategory.replace('_', ' ').title()} {rng.choice(VARIANTS)}",
        "brand": brand,
        "category": category,
        "subcategory": subcategory,
        "unit_cost": money(list_price * Decimal(str(rng.uniform(0.4, 0.7)))),
        "list_price": list_price,
        "is_active": True,
        "supplier_updated_at": as_of,
    }


def initial_catalog(rng: random.Random, n_skus: int, as_of: datetime) -> list[dict]:
    return [_new_product(rng, i, as_of) for i in range(1, n_skus + 1)]


def evolve_catalog(rng: random.Random, products: list[dict], changes, as_of: datetime) -> list[dict]:
    """Next day's snapshot: price changes, discontinued SKUs, new SKUs. Input is not modified."""
    next_products = []
    for p in products:
        p = dict(p)
        if p["is_active"]:
            if rng.random() < changes.discontinue_rate:
                p["is_active"] = False
                p["supplier_updated_at"] = as_of
            elif rng.random() < changes.price_change_rate:
                p["list_price"] = money(p["list_price"] * Decimal(str(rng.uniform(0.85, 1.2))))
                p["supplier_updated_at"] = as_of
        next_products.append(p)

    next_id = max(int(p["sku"].split("-")[1]) for p in products) + 1
    for i in range(changes.new_skus_per_day):
        next_products.append(_new_product(rng, next_id + i, as_of))
    return next_products


def to_csv(products: list[dict], snapshot_day: date, drift_day: date | None) -> str:
    """Render a snapshot. From drift_day on, the supplier adds a pack_size column unannounced."""
    drift = drift_day is not None and snapshot_day >= drift_day
    columns = COLUMNS + [DRIFT_COLUMN] if drift else COLUMNS
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(columns)
    for p in products:
        row = [
            p["sku"], p["product_name"], p["brand"], p["category"], p["subcategory"],
            f"{p['unit_cost']:.2f}", f"{p['list_price']:.2f}", str(p["is_active"]).lower(),
            p["supplier_updated_at"].strftime("%Y-%m-%d %H:%M:%S"),
        ]
        if drift:
            # Stable per SKU so consecutive files agree.
            row.append(PACK_SIZES[zlib.crc32(p["sku"].encode()) % len(PACK_SIZES)])
        writer.writerow(row)
    return out.getvalue()


def from_csv(text: str) -> list[dict]:
    """Parse a snapshot back into products (extra columns such as pack_size are ignored)."""
    products = []
    for row in csv.DictReader(io.StringIO(text)):
        products.append({
            "sku": row["sku"],
            "product_name": row["product_name"],
            "brand": row["brand"],
            "category": row["category"],
            "subcategory": row["subcategory"],
            "unit_cost": Decimal(row["unit_cost"]),
            "list_price": Decimal(row["list_price"]),
            "is_active": row["is_active"] == "true",
            "supplier_updated_at": datetime.strptime(
                row["supplier_updated_at"], "%Y-%m-%d %H:%M:%S"
            ).replace(tzinfo=UTC),  # file timestamps are UTC
        })
    return products


class SkuPicker:
    """Draws active SKUs with a long-tail popularity curve (a few products sell a lot).

    Popularity is derived from a hash of the SKU, so it is stable across runs without
    storing extra state.
    """

    def __init__(self, products: list[dict]):
        active = [p for p in products if p["is_active"]]
        if not active:
            raise ValueError("catalog has no active products")
        self.products = {p["sku"]: p for p in active}
        self.skus = [p["sku"] for p in active]
        weights = [1.0 / ((zlib.crc32(s.encode()) % len(active)) + 1) ** 0.8 for s in self.skus]
        self.cum_weights = []
        total = 0.0
        for w in weights:
            total += w
            self.cum_weights.append(total)

    def pick(self, rng: random.Random) -> dict:
        i = bisect.bisect_left(self.cum_weights, rng.random() * self.cum_weights[-1])
        return self.products[self.skus[i]]

    def pick_distinct(self, rng: random.Random, k: int) -> list[dict]:
        chosen: dict[str, dict] = {}
        k = min(k, len(self.skus))
        while len(chosen) < k:
            p = self.pick(rng)
            chosen[p["sku"]] = p
        return list(chosen.values())
