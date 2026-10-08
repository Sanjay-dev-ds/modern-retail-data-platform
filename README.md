# Retail Data Platform (AWS + Snowflake)

Synthetic retail data flowing through real AWS source services into S3, then Snowflake.

## Layout

| Path | Purpose |
|---|---|
| `infra/terraform` | All AWS infrastructure, one flat Terraform root (one file per concern) |
| `sql/pos` | POS source schema |
| `scripts` | `setup_host.sh` (EC2 first-boot setup), `init_db.sh` (creates the POS schema) |
| `generators` | `retail-gen`, the synthetic data generator (Python, managed with uv) |
| `airflow` | `docker-compose.yaml` for Airflow on the EC2 host, and `dags/` |
| `snowflake` | `setup.sql`: one-time Snowflake setup (warehouse, role, user, storage integration, RAW tables) |
| `dbt/retail` | dbt project: staging, core (SCD2 dims, incremental facts), marts |
| `docs` | Contracts and design notes |

## Infrastructure

| File | Resources |
|---|---|
| `network.tf` | VPC, 2 public and 2 private subnets, S3 gateway endpoint, **one security group** (PostgreSQL between members only, no other inbound) |
| `iam.tf` | **One service role**, `<prefix>-platform`, used by EC2, DMS, Firehose and Glue. Also `dms-vpc-role`, a role name AWS requires for DMS. |
| `s3.tf` | Lifecycle rules and an HTTPS-only policy on the existing shared bucket |
| `rds.tf` | POS PostgreSQL 16 with logical replication, plus connection secrets |
| `dms.tf` | Replication instance, endpoints and a full-load + CDC task to `pos/` (toggle with `enable_dms`) |
| `streaming.tf` | Kinesis stream to Firehose, writing to `clickstream/events/` |
| `glue.tf` | Glue database and crawler for Athena validation |
| `ec2.tf` | **One EC2 host** (`t3.medium`) running Airflow (Docker) and the generator |
| `snowflake.tf` | Key pair for the Snowflake service user, Airflow `snowflake_default` connection (Secrets Manager) |
| `budget.tf` | Monthly cost budget with email alerts |

The bucket `modern-retail-data-platform-20261007` holds both Terraform state (under `terraform/`) and the raw landing data. Terraform never creates or deletes it, and the platform role can only access the data prefixes.

## Deploy

One-time, create the bucket (state locking uses an S3 lock file, so no DynamoDB table):

```bash
bash infra/create_remote_state.sh
```

Then, from the repo root (edit `infra/terraform/terraform.tfvars` first; see the `.example` file):

```bash
make tf-init tf-validate tf-plan
make tf-apply
```

## Platform host

On first boot, user_data runs [`scripts/setup_host.sh`](scripts/setup_host.sh). It installs Docker, Docker Compose and uv, clones this repo to `/opt/retail` (from `repo_url`), syncs the generator environment, and starts Airflow with Docker Compose. The first boot takes about 5 minutes; the log is `/var/log/platform-setup.log`.

- **Airflow** runs as containers defined in [`airflow/docker-compose.yaml`](airflow/docker-compose.yaml): Airflow 3.3.2 (LocalExecutor) with a Postgres metadata DB. DAGs are read from `/opt/retail/airflow/dags`. Containers use the EC2 instance role, and connections come from Secrets Manager under `<prefix>/airflow/connections/` (`pos_db` is created by Terraform).
- **The generator** runs directly on the host with `uv run`.
- **Settings:** Terraform writes the non-secret values (bucket, Kinesis stream, DMS task, DB secret name, repo URL) to `/etc/retail/platform.env`. `setup_host.sh`, `init_db.sh`, `retail-gen` and Airflow's `.env` read this file directly, so no shell variables are needed. Login shells also load it, for `$RAW_BUCKET`, `$DMS_TASK_ARN`, ...
- **Secrets:** only the POS database credentials are in Secrets Manager. The Airflow keys and its metadata DB password are fixed, public values in `airflow/docker-compose.yaml`; that's deliberate for this experimental project.

## Run the generator on EC2

Everything below runs **on the EC2 host**, not on your laptop.

**1. Open a shell on the host.** Either run `make ssm` from your laptop, or in the AWS console go to EC2 → `retail-data-platform-dev-platform` → Connect → Session Manager. Then switch to root, because the generator's environment belongs to root:

```bash
sudo -i
tail -n 3 /var/log/platform-setup.log
cd /opt/retail && git pull
```

The log should end with `[setup] done`. If it doesn't, run `/usr/local/sbin/setup_host.sh` again (it is idempotent) and read the error.

**2. Create the POS schema** (once):

```bash
bash scripts/init_db.sh
```

**3. Seed 30 days of history** (once, before DMS starts; takes 2–3 minutes). This loads stores, customers, about 47k transactions with their lines and payments, and one catalog snapshot per day:

```bash
cd /opt/retail/generators
uv run retail-gen seed
```

**4. Start DMS** (full load, then CDC), and check progress:

```bash
aws dms start-replication-task --replication-task-arn "$DMS_TASK_ARN" --start-replication-task-type start-replication
aws dms describe-table-statistics --replication-task-arn "$DMS_TASK_ARN" \
  --query 'TableStatistics[].[TableName,FullLoadRows,Inserts,Updates,Deletes]' --output table
```

**5. Try one live cycle**: about 30 seconds of new sales, CDC changes and roughly 150 clickstream events:

```bash
uv run retail-gen run --once
```

**6. Run the live loop in the background** (it survives closing the session):

```bash
systemd-run --unit retail-gen --working-directory /opt/retail/generators --setenv HOME=/root \
  /usr/local/bin/uv run --frozen retail-gen run
journalctl -u retail-gen -f      # follow the logs (Ctrl+C stops following, not the generator)
systemctl stop retail-gen        # stop it
```

The unit isn't persistent: start it again after the instance is stopped and restarted.

**7. Check the landing data:**

```bash
aws s3 ls "s3://$RAW_BUCKET/pos/pos/" --recursive | tail
aws s3 ls "s3://$RAW_BUCKET/clickstream/events/" --recursive | tail   # Firehose flushes about every 60 s
aws s3 ls "s3://$RAW_BUCKET/catalog/products/" --recursive | tail
```

**Notes:**
- **Reset before DMS:** `uv run retail-gen seed --force` truncates the POS tables and reloads them. Never do this after DMS has started, because DMS does not replicate `TRUNCATE`.
- **Volumes and defect rates** are set in [`generators/config/default.yaml`](generators/config/default.yaml). The data contract is [`docs/source-contracts.md`](docs/source-contracts.md).

## Airflow on EC2

| Task | Command (on the host, as root, in `/opt/retail/airflow`) |
|---|---|
| UI | From your laptop, run `make airflow-ui`, then open http://localhost:8080. There's no login, because it's only reachable through the tunnel. |
| Status / logs | `docker compose ps`, `docker compose logs -f airflow-scheduler` |
| CLI | `docker compose exec airflow-scheduler airflow dags list` |
| Deploy DAGs | `git -C /opt/retail pull` (picked up automatically) |
| Restart / upgrade | `/usr/local/sbin/setup_host.sh` (it copies `platform.env` to `.env` and runs `docker compose up -d`). To change the version, edit `AIRFLOW_VERSION` in `/etc/retail/platform.env` first. |

## Load into Snowflake (Airflow + dbt + Cosmos)

```
S3 (pos/, clickstream/events/, catalog/products/)
  │  storage integration S3_RAW_INT (Snowflake assumes the platform IAM role)
  ▼
RETAIL.RAW      COPY INTO, hourly (Airflow task group load_raw). Already-loaded files are skipped.
  ▼  dbt via Cosmos: one Airflow task per model, its tests right after, plus source freshness
RETAIL.STAGING  views: typed, deduplicated, latest CDC version per key, is_deleted flag
RETAIL.CORE     dim_date, dim_store / dim_customer / dim_product (SCD2),
                fct_sales_lines, fct_payments, fct_sessions (incremental merge)
RETAIL.MARTS    mart_daily_sales, mart_web_funnel
```

**Surrogate keys (Kimball):**
- `store_sk`, `customer_sk` and `product_sk` are meaningless sequential integers, assigned **once** when a dimension version is first inserted and never changed. The SCD2 dimensions are incremental merges ([`macros/surrogate_key.sql`](dbt/retail/macros/surrogate_key.sql)). A new version gets `max + 1`, and the previous version's `valid_to`/`is_current` are updated.
- `-1` is the **Unknown** member. Fact keys are never null: orphan SKUs, anonymous shoppers and unmatched stores point at `-1`.
- `date_sk` is a `YYYYMMDD` integer, the accepted smart-key exception for dates.
- Never full-refresh a dimension on its own, because its keys would be re-assigned under facts that already hold them. Rebuild dimensions and facts together.

The DAG is [`airflow/dags/retail_elt.py`](airflow/dags/retail_elt.py). The Airflow image ([`airflow/Dockerfile`](airflow/Dockerfile)) adds Cosmos and puts dbt-snowflake in its own venv. Snowflake access uses key-pair auth: Terraform generates the key and stores it in the `snowflake_default` Airflow connection in Secrets Manager.

**One-time setup:**

1. Apply Terraform. This creates the key pair and the Airflow `snowflake_default` connection:
   ```bash
   make tf-plan tf-apply
   ```
2. Copy the setup script, which Terraform renders with your role ARN, bucket and public key:
   ```bash
   terraform -chdir=infra/terraform output -raw snowflake_setup_sql | pbcopy
   ```
   In Snowsight, open a new SQL worksheet, paste, switch to the **ACCOUNTADMIN** role and click **Run All**. It creates the warehouse, role, service user, storage integration, stages and RAW tables, and it's safe to re-run.
3. The last result (`DESC INTEGRATION S3_RAW_INT`) shows `STORAGE_AWS_IAM_USER_ARN` and `STORAGE_AWS_EXTERNAL_ID`. Add them to `infra/terraform/terraform.tfvars`, together with your account identifier (Snowsight: your name → **Account** → **View account details**, in the form `ORGNAME-ACCOUNTNAME`):
   ```hcl
   snowflake_account      = "ORGNAME-ACCOUNTNAME"
   snowflake_iam_user_arn = "<STORAGE_AWS_IAM_USER_ARN>"
   snowflake_external_id  = "<STORAGE_AWS_EXTERNAL_ID>"
   ```
4. Apply again. This lets Snowflake assume the platform role and puts the account into the Airflow connection:
   ```bash
   make tf-plan tf-apply
   ```
   In Snowsight, `LIST @RETAIL.RAW.POS_STAGE;` should now list the DMS files.
5. On the EC2 host, as root, pull and rebuild Airflow with Cosmos and dbt (the first build takes a few minutes):
   ```bash
   git -C /opt/retail pull && /usr/local/sbin/setup_host.sh
   ```
6. Run `make airflow-ui` from your laptop, then open http://localhost:8080, unpause `retail_elt` and trigger it.

**Checks in Snowsight:**
- `SELECT COUNT(*) FROM RETAIL.RAW.POS_TRANSACTIONS;` should be about the RDS row count plus CDC changes.
- Run the DAG twice. The second `copy_*` tasks load 0 files, and `fct_sales_lines` keeps the same row count, which shows the incremental merge doesn't duplicate rows.
- The planted defects (orphan SKUs, invalid quantities, payment mismatches, null emails) appear as **warnings** in the dbt test tasks. They don't fail the run.

**Cost:** the `RETAIL_WH` warehouse is XSMALL and suspends after 60 s idle. Each hourly run keeps it up for a minute or two. Pause `retail_elt` in the Airflow UI when you aren't using it.

## Cost control

- `enable_dms = false` followed by `make tf-plan tf-apply` removes the replication instance.
- `make ec2-stop` / `make ec2-start` stops and starts the platform host.
- Stop the RDS instance when idle (AWS restarts it automatically after 7 days).
- `make tf-destroy` removes everything except the shared bucket and its data. Never delete `terraform/` in the bucket.
- Set `alert_email` for budget alerts.
