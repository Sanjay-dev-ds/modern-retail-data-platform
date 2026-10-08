# Source Contracts

Three synthetic sources, one per ingestion pattern. They describe a retailer with physical stores and an online shop. Generator settings live in [`generators/config/default.yaml`](../generators/config/default.yaml).

All sources land in one bucket, `modern-retail-data-platform-20261007`. The same bucket holds Terraform state under `terraform/`, which is reserved: nothing else writes there, and no platform role has access to it.

| # | Source | Business role | Mechanism | S3 location | Format |
|---|---|---|---|---|---|
| A | POS / orders DB (RDS PostgreSQL, schema `pos`) | System of record for store and online sales | DMS full load + CDC | `pos/pos/<table>/` (CDC files under `YYYYMMDD/`) | Parquet + `Op`, `_dms_commit_ts` |
| B | Web/app clickstream | Shopper behaviour | Kinesis Data Streams → Firehose | `clickstream/events/dt=YYYY-MM-DD/hh=HH/` | JSON Lines, gzip |
| C | Product catalog (third-party supplier feed) | Product reference data | Daily file upload | `catalog/products/dt=YYYY-MM-DD/` | CSV, full snapshot |

General rules:
- Landing is immutable: files are only ever added, never rewritten.
- Batch file names: `<entity>_<yyyymmddHHMMSS>.csv`.
- All timestamps are UTC.
- Clickstream producers must not append newlines, because Firehose adds the delimiter. The partition key is `session_id`.

---

## A. POS database

DDL: [`sql/pos/01_schema.sql`](../sql/pos/01_schema.sql). There are 30 days of backdated history, followed by live inserts and changes.

### Tables and grain

| Table | Grain | Key | Notes |
|---|---|---|---|
| `stores` | one store | `store_id` | `store_id = 0` is "Online". `format`/`region` change rarely (SCD2). |
| `customers` | one loyalty customer | `customer_id` | `loyalty_tier` changes (SCD2). `email`/`phone` are PII. Anonymous shoppers have no row. |
| `transactions` | one sale (header) | `transaction_id` | `channel = online` ⇔ `store_id = 0`. `customer_id` null = anonymous. |
| `transaction_lines` | one product on one sale | `transaction_id, line_no` | **Sales fact grain.** `sku` has no FK because it comes from the catalog. |
| `payments` | one tender | `payment_id` | About 5% of sales have more than one payment. **Never join to lines** (fan-out). |

### Column dictionary

| Table.column | Type | Meaning |
|---|---|---|
| `stores.region` | text | north, south, east, west, online |
| `stores.format` | text | hyper, express, outlet, online |
| `customers.loyalty_tier` | text | bronze, silver, gold |
| `customers.home_store_id` | int | store the customer signed up at |
| `transactions.txn_ts` | timestamptz | business time of the sale (use this for reporting) |
| `transactions.status` | text | completed, voided, returned |
| `transactions.total_amount` | numeric(12,2) | Σ(quantity × unit_price − discount_amount) over the lines |
| `transactions.created_at` / `updated_at` | timestamptz | insert time / last change (history rows are backdated) |
| `transaction_lines.unit_price` | numeric(10,2) | price charged; can differ from the catalog `list_price` |
| `transaction_lines.promo_code` | text | null when no promotion applied |
| `payments.method` | text | card, cash, wallet, gift_card |

### How rows change (captured by DMS CDC)

| Change | Table | When | In S3 |
|---|---|---|---|
| New sale | transactions, lines, payments | continuously | `Op = I` |
| Void | transactions.status | minutes after the sale (1%) | `Op = U` |
| Return | transactions.status | days after the sale (2%) | `Op = U` |
| Tier change / email fix | customers | daily, a few rows | `Op = U` |
| Format / region change | stores | rare | `Op = U` |
| Test-transaction cleanup | transactions (+ its lines and payments) | rare (0.05%) | `Op = D` |

**DMS specifics:**
- Full-load files (`LOAD*.parquet`) sit directly in the table folder. CDC files sit under `YYYYMMDD/`.
- `_dms_commit_ts` is the source commit time. Use it to keep the latest version of each key, because a single CDC batch can contain several changes to the same row.
- With the `test_decoding` plugin, **delete rows (`Op = D`) carry only the primary-key columns**. Every other column is null.

---

## B. Clickstream events

One JSON object per Kinesis record. The stream is live only, with no history.

| Field | Type | Meaning |
|---|---|---|
| `event_id` | string (UUID) | unique per event; duplicates are a known defect |
| `event_type` | string | page_view, product_view, add_to_cart, checkout_started, purchase |
| `event_ts` | string (ISO-8601 UTC) | when it happened on the device (**use this, not the partition**) |
| `session_id` | string (UUID) | browsing session; also the Kinesis partition key |
| `anonymous_id` | string (UUID) | device/browser cookie, stable across sessions |
| `customer_id` | integer \| null | set after login; joins to `pos.customers` |
| `page_url` | string | e.g. `/product/SKU-00042` |
| `sku` | string \| null | product events, add_to_cart |
| `quantity` | integer \| null | add_to_cart |
| `order_id` | string (UUID) \| null | purchase only; equals `pos.transactions.transaction_id` (channel = online) |
| `device` | string | web, ios, android |
| `utm_source`, `utm_medium`, `utm_campaign` | string \| null | marketing attribution, set on the first event of a session |
| `schema_version` | integer | starts at 1 |

The funnel `page_view → product_view → add_to_cart → checkout_started → purchase` drops off at every step.

**Event time vs arrival time:** Firehose partitions `dt=/hh=` by **arrival** time. Late events (2%) arrive hours after their `event_ts` and land in a later partition. Incremental models need a lookback window based on `event_ts`.

---

## C. Product catalog (supplier file)

A full snapshot every day: `catalog/products/dt=YYYY-MM-DD/products_<yyyymmddHHMMSS>.csv`. Each file has a header row, is UTF-8 and is comma-separated.

| Column | Type | Meaning |
|---|---|---|
| `sku` | string | product key, e.g. `SKU-00042` |
| `product_name` | string | |
| `brand` | string | |
| `category`, `subcategory` | string | product hierarchy |
| `unit_cost` | decimal | supplier cost |
| `list_price` | decimal | shelf price on that day |
| `is_active` | boolean | false once discontinued (the row stays in later files) |
| `supplier_updated_at` | timestamp | when the supplier last changed the row |

**Daily changes:** about 2% of SKUs get a new price, ~3 new SKUs appear, and ~0.2% are discontinued. Changes are only visible by comparing consecutive snapshots, which makes this the SCD2 snapshot source.

**Schema drift:** from `schema_drift_day` onward, the file gains a `pack_size` column. The file is the supplier's format, and they don't announce changes.

---

## Shared keys

| Key | Owned by | Referenced by |
|---|---|---|
| `sku` | catalog CSV | `pos.transaction_lines.sku`, clickstream `sku` |
| `customer_id` | `pos.customers` | `pos.transactions.customer_id`, clickstream `customer_id` |
| `store_id` | `pos.stores` (`0` = Online) | `pos.transactions.store_id`, `pos.customers.home_store_id` |
| `transaction_id` | `pos.transactions` | `pos.transaction_lines`, `pos.payments`, clickstream `order_id` |

## Injected defects

The generator corrupts a small, configurable share of records. Each defect has a column where it appears and a check downstream that must catch it.

| Defect | Rate | Where | Expected detection |
|---|---|---|---|
| Duplicate events | 1% | clickstream `event_id` | dedupe in staging, then a `unique` test |
| Late-arriving events | 2% | clickstream `event_ts` ≪ arrival | incremental lookback window |
| Null values | 0.5% | `customers.email`; `transactions.customer_id` on online orders | `not_null` where the business requires it |
| Invalid values | 0.5% | `transaction_lines.quantity <= 0` or `unit_price = 0` on completed sales | range / expression tests |
| Orphan SKU | 0.3% | `transaction_lines.sku` not in the catalog | `relationships` test (warn) |
| Payment mismatch | 0.2% | Σ `payments.amount` ≠ `transactions.total_amount` | reconciliation test |
| CDC noise | n/a | several changes per key in a batch; key-only delete rows | latest-by-`_dms_commit_ts` dedupe, delete flag |
| Schema drift | once | catalog `pack_size` column | explicit column list, schema test |

Online orders created before clickstream went live have no `purchase` event. That's a known gap, not a defect: reconcile only from the clickstream start date.
