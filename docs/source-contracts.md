# Source Contracts

All sources land in one bucket, `modern-retail-data-platform-20261007` (Terraform variable `raw_bucket_name`). The same bucket holds Terraform state under `terraform/`, which is reserved: nothing else writes there, and no platform role has access to it.

| Source | Mechanism | S3 location | Format |
|---|---|---|---|
| POS (RDS PostgreSQL, schema `pos`) | DMS full load + CDC | `pos/pos/<table>/` (CDC files under `YYYY/MM/DD/`) | Parquet, columns `Op` (I/U/D) and `_dms_commit_ts` |
| Clickstream | Kinesis Data Streams -> Firehose | `clickstream/events/dt=YYYY-MM-DD/hh=HH/` | JSON Lines, gzip |
| Product catalog | Script upload | `catalog/products/dt=YYYY-MM-DD/` | CSV (daily full snapshot) |
| Inventory | Script upload | `inventory/snapshots/dt=YYYY-MM-DD/` | CSV |
| Marketing spend | Script upload | `marketing/spend/dt=YYYY-MM-DD/` | CSV |
| Reference (calendar, holidays) | Script upload | `reference/<entity>/` | CSV |

Rules:
- Landing is immutable; files are never rewritten, only added.
- Batch file names: `<entity>_<yyyymmddHHMMSS>.csv`.
- Clickstream producers must not append newlines; Firehose adds the delimiter.
- Clickstream partition key is `session_id`.
