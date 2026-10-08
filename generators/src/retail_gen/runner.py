"""Orchestration of the three sources.

seed : 30 days of backdated POS history + one catalog snapshot per history day (no clickstream).
run  : live loop. Every cycle: store openings, sign-ups and sales, CDC changes (voids and returns
       with refunds, deletes, SCD2 updates),
       clickstream sessions to Kinesis, and today's catalog snapshot once per day.
"""

from __future__ import annotations

import logging
import random
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from datetime import time as dtime

from faker import Faker

from retail_gen.config import Config
from retail_gen.entities.catalog import SkuPicker, evolve_catalog, initial_catalog
from retail_gen.entities.clickstream import browse_session, purchase_session
from retail_gen.entities.common import ONLINE_HOURLY, STORE_HOURLY, WEEKDAY_FACTOR, poisson
from retail_gen.entities.customers import make_customers, new_customer
from retail_gen.entities.stores import ONLINE_STORE_ID, make_stores, new_store
from retail_gen.entities.transactions import Sale, make_sale
from retail_gen.sources import catalog_feed, clickstream_feed, pos
from retail_gen.writers.events import EventSink
from retail_gen.writers.objects import ObjectStore
from retail_gen.writers.postgres import connect

log = logging.getLogger(__name__)

CATALOG_PUBLISH_TIME = dtime(6, 0)  # the supplier drops the daily file at 06:00 UTC


@dataclass
class Sinks:
    objects: ObjectStore
    events: EventSink
    db_secret_id: str


def _party(rng: random.Random, cfg: Config, online: bool, store_ids: list[int], customer_ids: list[int]):
    """(store_id, customer_id) for a new sale."""
    if online:
        customer_id = rng.choice(customer_ids)
        if rng.random() < cfg.defects.null_values:
            customer_id = None  # defect: online orders should always have a customer
        return ONLINE_STORE_ID, customer_id
    customer_id = None if rng.random() < cfg.mix.anonymous_share else rng.choice(customer_ids)
    return rng.choice(store_ids), customer_id


def _sale(rng, cfg, picker, ts, online, store_ids, customer_ids) -> Sale:
    store_id, customer_id = _party(rng, cfg, online, store_ids, customer_ids)
    return make_sale(
        rng,
        ts=ts,
        store_id=store_id,
        customer_id=customer_id,
        picker=picker,
        avg_lines=cfg.scale.avg_lines_per_transaction,
        split_payment_rate=cfg.mix.split_payment_rate,
        defects=cfg.defects,
    )


# ---------------------------------------------------------------- seed

def seed(cfg: Config, sinks: Sinks, force: bool = False) -> None:
    rng = random.Random(cfg.seed)
    fake = Faker()
    fake.seed_instance(cfg.seed)
    now = datetime.now(UTC)
    start_day = now.date() - timedelta(days=cfg.scale.history_days)
    history_start = datetime.combine(start_day, dtime(0), UTC)

    with connect(sinks.db_secret_id) as conn:
        if pos.is_seeded(conn) or catalog_feed.latest(sinks.objects):
            if not force:
                raise SystemExit(
                    "Already seeded (POS rows or catalog files exist). Use --force to reload: it "
                    "truncates the POS tables and overwrites the history catalog files. Only do "
                    "this before DMS is started."
                )
            log.warning("--force: truncating POS tables")
            pos.truncate_all(conn)

        stores = make_stores(rng, fake, cfg.scale.stores, history_start)
        store_ids = [s["store_id"] for s in stores if s["store_id"] != ONLINE_STORE_ID]
        customers = make_customers(
            rng, fake, cfg.scale.customers, store_ids, history_start, cfg.defects.null_values
        )
        customer_ids = [c["customer_id"] for c in customers]
        pos.insert_rows(conn, "pos.stores", stores)
        pos.insert_rows(conn, "pos.customers", customers)
        conn.commit()
        log.info("inserted %d stores (incl. online), %d customers", len(stores), len(customers))

        products: list[dict] = []
        for i in range(cfg.scale.history_days):
            day = start_day + timedelta(days=i)
            as_of = datetime.combine(day, CATALOG_PUBLISH_TIME, UTC)
            if i == 0:
                products = initial_catalog(rng, cfg.scale.skus, as_of)
            else:
                products = evolve_catalog(rng, products, cfg.catalog, as_of)
            key = catalog_feed.publish(sinks.objects, products, as_of, cfg.defects.schema_drift_day)
            picker = SkuPicker(products)

            sales = []
            n = poisson(rng, cfg.scale.transactions_per_day * WEEKDAY_FACTOR[day.weekday()])
            for _ in range(n):
                online = rng.random() < cfg.mix.online_share
                hour = rng.choices(range(24), ONLINE_HOURLY if online else STORE_HOURLY)[0]
                ts = datetime.combine(day, dtime(hour), UTC) + timedelta(seconds=rng.uniform(0, 3600))
                sale = _sale(rng, cfg, picker, ts, online, store_ids, customer_ids)
                pos.backdate_status(rng, sale, cfg.mutations.void_rate, cfg.mutations.return_rate, now)
                sales.append(sale)
            pos.insert_sales(conn, sales)
            conn.commit()
            log.info("%s: %d sales, catalog %s (%d SKUs)", day, len(sales), key, len(products))

    log.info("seed complete. Next: start the DMS task (full load + CDC), then `retail-gen run`")


# ---------------------------------------------------------------- live loop

def _todays_picker(cfg: Config, sinks: Sinks, rng: random.Random, now: datetime) -> SkuPicker:
    """Load the latest catalog; publish today's snapshot first if it does not exist yet."""
    found = catalog_feed.latest(sinks.objects)
    if found is None:
        raise SystemExit("No catalog snapshot found. Run `retail-gen seed` first.")
    day, products = found
    if day < now.date():
        products = evolve_catalog(rng, products, cfg.catalog, now)
        key = catalog_feed.publish(sinks.objects, products, now, cfg.defects.schema_drift_day)
        log.info("published catalog snapshot %s (%d SKUs)", key, len(products))
    return SkuPicker(products)


def _cycle(cfg, sinks, conn, rng, fake, picker, store_ids, customer_ids, now) -> dict:
    cycle_s = cfg.targets.incremental_cycle_seconds
    day_fraction = cycle_s / 86400
    per_day = cfg.scale.transactions_per_day * WEEKDAY_FACTOR[now.weekday()]
    w_store = STORE_HOURLY[now.hour] * (1 - cfg.mix.online_share)
    w_online = ONLINE_HOURLY[now.hour] * cfg.mix.online_share
    expected_sales = per_day * day_fraction * (w_store + w_online)
    p_online = w_online / (w_store + w_online) if (w_store + w_online) else 1.0

    m = cfg.mutations

    # 1. New store openings and loyalty sign-ups (inserts), usable by sales in this same cycle.
    openings = [
        new_store(rng, fake, store_ids[-1] + i + 1, now.date(), now)
        for i in range(poisson(rng, m.new_stores_per_day * day_fraction))
    ]
    pos.insert_rows(conn, "pos.stores", openings)
    store_ids.extend(st["store_id"] for st in openings)

    signups = [
        new_customer(rng, fake, customer_ids[-1] + i + 1, store_ids,
                     now - timedelta(seconds=rng.uniform(0, cycle_s)), cfg.defects.null_values, tier="bronze")
        for i in range(poisson(rng, m.new_customers_per_day * day_fraction))
    ]
    pos.insert_rows(conn, "pos.customers", signups)
    customer_ids.extend(c["customer_id"] for c in signups)

    # 2. New sales
    sales = []
    for _ in range(poisson(rng, expected_sales)):
        ts = now - timedelta(seconds=rng.uniform(0, cycle_s))
        sales.append(_sale(rng, cfg, picker, ts, rng.random() < p_online, store_ids, customer_ids))
    pos.insert_sales(conn, sales)

    # 3. Changes to existing rows (DMS turns these into Op = U / D), refunds as new payments
    voided = pos.void_recent(conn, poisson(rng, m.void_rate * expected_sales), now)
    returned = pos.return_older(conn, poisson(rng, m.return_rate * expected_sales), now)
    stats = {
        "new_stores": len(openings),
        "new_customers": len(signups),
        "sales": len(sales),
        "voids": len(voided),
        "returns": len(returned),
        "refunds": pos.refund_payments(conn, voided + returned, now),
        "deletes": pos.delete_test_transactions(conn, poisson(rng, m.delete_rate * expected_sales)),
        "store_changes": pos.change_stores(
            conn, rng, poisson(rng, m.store_change_rate * len(store_ids) * day_fraction), now),
        "customer_changes": pos.change_customers(
            conn, rng, poisson(rng, m.tier_change_rate * len(customer_ids) * day_fraction), now),
    }
    conn.commit()  # orders exist before their purchase events are sent

    # 4. Clickstream: a purchase session per online sale, browse sessions for the rest of the budget
    events = [e for s in sales if s.txn["channel"] == "online" for e in purchase_session(rng, s, picker)]
    budget = cfg.targets.clickstream_events_per_second * cycle_s - len(events)
    late = 0
    while budget > 0:
        if rng.random() < cfg.defects.late_arriving:
            end = now - timedelta(hours=rng.uniform(1, 6))  # buffered on a phone, sent now
            late += 1
        else:
            end = now - timedelta(seconds=rng.uniform(0, cycle_s))
        session = browse_session(rng, end, picker, customer_ids)
        events.extend(session)
        budget -= len(session)
    stats["events"] = clickstream_feed.send(sinks.events, rng, events, cfg.defects.duplicate_events)
    stats["late_sessions"] = late
    return stats


def run(cfg: Config, sinks: Sinks, once: bool = False) -> None:
    rng = random.Random()  # live data does not need to be reproducible
    fake = Faker()
    cycle_s = cfg.targets.incremental_cycle_seconds
    with connect(sinks.db_secret_id) as conn:
        if not pos.is_seeded(conn):
            raise SystemExit("POS tables are empty. Run `retail-gen seed` first.")
        store_ids, customer_ids = pos.reference_ids(conn)
        picker, picker_day = None, None
        log.info("live loop: every %ds -> RDS, %s, %s", cycle_s, sinks.events, sinks.objects)
        while True:
            started = time.monotonic()
            now = datetime.now(UTC)
            if picker_day != now.date():
                picker, picker_day = _todays_picker(cfg, sinks, rng, now), now.date()
            stats = _cycle(cfg, sinks, conn, rng, fake, picker, store_ids, customer_ids, now)
            log.info("cycle: %s", " ".join(f"{k}={v}" for k, v in stats.items()))
            if once:
                return
            time.sleep(max(0.0, cycle_s - (time.monotonic() - started)))
