{% docs __overview__ %}
# Retail data platform: dbt project

Synthetic retailer with physical stores and an online shop. Three sources land in S3 and are
loaded hourly into Snowflake `RETAIL.RAW` by Airflow (`COPY INTO`); dbt (run by Airflow through
Cosmos) models them into staging, core and marts.

| Source | System | Path to Snowflake |
|---|---|---|
| POS database (`pos` schema) | RDS PostgreSQL | DMS full load + CDC → S3 Parquet → `RAW.POS_*` |
| Clickstream | Web / app events | Kinesis → Firehose → S3 JSON → `RAW.CLICKSTREAM_EVENTS` |
| Product catalog | Supplier file | Daily CSV snapshot → S3 → `RAW.CATALOG_PRODUCTS` |

## Layers

| Layer | Schema | Materialization | Purpose |
|---|---|---|---|
| Sources | `RAW` | tables (COPY INTO) | Files as delivered. POS and clickstream rows are whole records in a `record` VARIANT. |
| Staging | `STAGING` | views | Typed columns, one row per business key (latest CDC version), duplicates removed, `is_deleted` flag. `*_cdc` views keep every version. |
| Core | `CORE` | incremental tables | Star schema: SCD2 dimensions with integer surrogate keys, and facts at a stated grain. |
| Marts | `MARTS` | tables | Aggregates for BI. |

## Models and grain

| Model | Grain (one row per…) | Key |
|---|---|---|
| `dim_date` | calendar day | `date_sk` (YYYYMMDD) |
| `dim_store` | store **version** (SCD2) | `store_sk` |
| `dim_customer` | loyalty customer **version** (SCD2) | `customer_sk` |
| `dim_product` | product (SKU) **version** (SCD2) | `product_sk` |
| `fct_sales_lines` | product on a sale (transaction line) | `transaction_id`, `line_no` |
| `fct_payments` | tender (payment or refund) | `payment_id` |
| `fct_sessions` | web/app browsing session | `session_id` |
| `mart_daily_sales` | day × store × channel | `txn_date`, `store_id`, `channel` |
| `mart_web_funnel` | day | `session_date` |

## Conventions
- **Surrogate keys** (`*_sk`): meaningless sequential integers assigned once when a dimension
  version is created and never changed. `-1` is the **Unknown** member; fact keys are never null.
  Dates use the integer smart key `YYYYMMDD`.
- **SCD2**: `valid_from` ≤ t < `valid_to` (null `valid_to` = current version). The first version
  starts 1900-01-01, because history before the DMS full load is unknown.
- **Point-in-time joins**: facts carry the dimension key of the version valid at the time of the
  event.
- **Deletes**: hard deletes in the source arrive as CDC rows with only the key; they are kept with
  `is_deleted = true`. Filter them out in reporting.
- **Metadata columns**: `_file` (S3 file the row came from), `_loaded_at` (Snowflake load time),
  `_dms_commit_ts` (source commit time).

## Data quality
Planted source defects are tested with **severity: warn** (reported, not failing): null emails,
online orders without a customer, invalid quantities/prices, orphan SKUs, payment mismatches,
duplicate and late clickstream events, catalog schema drift. Structural guarantees (keys unique
and not null, relationships between facts and dimensions) are errors.
{% enddocs %}
