"""Clickstream sessions (source B). Each event is a dict with every contract field present."""

from __future__ import annotations

import random
import uuid
from datetime import datetime, timedelta

from retail_gen.entities.catalog import SkuPicker
from retail_gen.entities.common import iso_utc, new_uuid
from retail_gen.entities.transactions import Sale

SCHEMA_VERSION = 1
DEVICES = (["web", "ios", "android"], [0.55, 0.3, 0.15])
UTM = [
    (None, None, None),
    (None, None, None),
    ("google", "cpc", "brand_search"),
    ("facebook", "paid_social", "autumn_sale"),
    ("newsletter", "email", "weekly_deals"),
]
_ANON_NAMESPACE = uuid.UUID("6f1c2b8e-3a4d-4e5f-8a9b-0c1d2e3f4a5b")


def anonymous_id_for(customer_id: int) -> str:
    """Known customers keep one device cookie across sessions."""
    return str(uuid.uuid5(_ANON_NAMESPACE, str(customer_id)))


class _Session:
    def __init__(self, rng: random.Random, customer_id: int | None, logged_in: bool):
        self.rng = rng
        self.session_id = str(new_uuid(rng))
        self.anonymous_id = anonymous_id_for(customer_id) if customer_id else str(new_uuid(rng))
        self.customer_id = customer_id
        self.logged_in = logged_in
        self.device = rng.choices(*DEVICES)[0]
        self.utm = rng.choice(UTM)
        self.events: list[dict] = []

    def add(self, event_type: str, page_url: str, *, sku=None, quantity=None, order_id=None) -> None:
        first = not self.events
        self.events.append({
            "event_id": str(new_uuid(self.rng)),
            "event_type": event_type,
            "event_ts": None,  # filled by stamp()
            "session_id": self.session_id,
            "anonymous_id": self.anonymous_id,
            "customer_id": self.customer_id if self.logged_in else None,
            "page_url": page_url,
            "sku": sku,
            "quantity": quantity,
            "order_id": order_id,
            "device": self.device,
            "utm_source": self.utm[0] if first else None,
            "utm_medium": self.utm[1] if first else None,
            "utm_campaign": self.utm[2] if first else None,
            "schema_version": SCHEMA_VERSION,
        })

    def stamp(self, *, start: datetime | None = None, end: datetime | None = None) -> list[dict]:
        """Space events 5-90 s apart, anchored at start or so the last event lands exactly at end."""
        gaps = [timedelta(seconds=self.rng.uniform(5, 90)) for _ in self.events[1:]]
        if start is None:
            start = end - sum(gaps, timedelta())
        ts = start
        for event, gap in zip(self.events, [timedelta()] + gaps):
            ts += gap
            event["event_ts"] = iso_utc(ts)
        return self.events


def purchase_session(rng: random.Random, sale: Sale, picker: SkuPicker) -> list[dict]:
    """Browsing that ends in the purchase of `sale`; the purchase event's time equals txn_ts."""
    customer_id = sale.txn["customer_id"]
    s = _Session(rng, customer_id, logged_in=customer_id is not None and rng.random() < 0.5)
    s.add("page_view", "/")
    for _ in range(rng.randint(0, 2)):  # products looked at but not bought
        p = picker.pick(rng)
        s.add("product_view", f"/product/{p['sku']}", sku=p["sku"])
    for line in sale.lines:
        s.add("product_view", f"/product/{line['sku']}", sku=line["sku"])
        s.add("add_to_cart", "/cart", sku=line["sku"], quantity=line["quantity"])
    s.logged_in = customer_id is not None  # login happens at checkout at the latest
    s.add("checkout_started", "/checkout")
    s.add("purchase", "/checkout/confirmation", order_id=str(sale.txn["transaction_id"]))
    return s.stamp(end=sale.txn["txn_ts"])


def browse_session(
    rng: random.Random, end: datetime, picker: SkuPicker, customer_ids: list[int]
) -> list[dict]:
    """A session that never purchases (funnel drop-off at every step), last event at `end`."""
    customer_id = rng.choice(customer_ids) if rng.random() < 0.25 else None
    s = _Session(rng, customer_id, logged_in=customer_id is not None)
    s.add("page_view", "/")
    if rng.random() < 0.6:
        category = picker.pick(rng)["category"]
        s.add("page_view", f"/category/{category}")
    cart = []
    while rng.random() < 0.65 and len(s.events) < 15:
        p = picker.pick(rng)
        s.add("product_view", f"/product/{p['sku']}", sku=p["sku"])
        if rng.random() < 0.2:
            cart.append(p["sku"])
            s.add("add_to_cart", "/cart", sku=p["sku"], quantity=1)
    if cart and rng.random() < 0.3:
        s.add("checkout_started", "/checkout")  # abandoned checkout
    return s.stamp(end=end)
