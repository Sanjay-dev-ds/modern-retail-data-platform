# Retail Data Platform (AWS + Snowflake)

Synthetic retail data flowing through real AWS source services into S3, then Snowflake.

## Layout

| Path | Purpose |
|---|---|
| `infra/terraform` | All AWS infrastructure, one flat Terraform root (one file per concern) |
| `sql/pos` | POS source schema |
| `scripts` | Operational helpers (`scripts/airflow/install_airflow.sh` provisions the platform host) |
| `generators` | Synthetic data generators (config, entities, sources, writers) |
| `airflow/dags` | Airflow DAGs, read on the host from `/opt/retail/airflow/dags` |
| `snowflake` | DDL, Snowpipe, RBAC scripts (later phase) |
| `dbt/retail` | staging, core, marts models (later phase) |
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
| `ec2.tf` | **One EC2 host** (`t3.medium`) running Airflow and the generators |
| `budget.tf` | Monthly cost budget with email alerts |

The bucket `modern-retail-data-platform-20261007` holds both Terraform state (under `terraform/`) and the raw landing data. Terraform never creates or deletes it, and the platform role can only access the data prefixes.

## Deploy

One-time, create the bucket and lock table:

```bash
bash infra/create_remote_state.sh
```

Then, from the repo root (edit `infra/terraform/terraform.tfvars` first; see the `.example` file):

```bash
make tf-init tf-validate tf-plan
make tf-apply
```

## Bring the sources up

1. `make ssm` to open a shell on the platform host. If `repo_url` is unset, clone this repo into `/opt/retail` as the `airflow` user, then rerun `sudo /usr/local/sbin/install_airflow.sh` to install the generator dependencies.
2. `bash scripts/init_db.sh` creates the `pos` schema and confirms `rds.logical_replication` is `on`.
3. Run the seed load (dimensions, then history) once the generator is implemented.
4. `make dms-start` (full load, then CDC). Check `aws dms describe-table-statistics` and `pos/pos/<table>/` in S3.
5. Start the incremental generator (DB changes + Kinesis events).
6. Optional: run the Glue crawler, then query with Athena.

## Platform host (Airflow + generators)

On first boot, user_data runs `scripts/airflow/install_airflow.sh`, which installs:

- Airflow 3 (`airflow_version`, default 3.3.2) with the amazon, postgres and snowflake providers in `/opt/airflow/venv`
- dbt-snowflake in `/opt/airflow/dbt-venv`
- the generator dependencies in `/opt/airflow/gen-venv`
- a local PostgreSQL 15 metadata DB, with LocalExecutor
- systemd services `airflow-api-server`, `airflow-scheduler`, `airflow-dag-processor` and `airflow-triggerer`, plus a daily log cleanup timer

The first install takes about 5–10 minutes. Follow it with `sudo tail -f /var/log/platform-install.log`.

| Task | How |
|---|---|
| Shell | `make ssm`, then `sudo airflow-cli dags list` |
| UI | `make airflow-ui`, then open http://localhost:8080 and log in as `admin`. The password is in `/opt/airflow/simple_auth_manager_passwords.json.generated`. |
| DAGs | Read from `/opt/retail/airflow/dags`. Deploy with `sudo -u airflow git -C /opt/retail pull`. |
| Connections | The Secrets Manager backend reads `<prefix>/airflow/connections/<conn_id>`. `pos_db` is created by Terraform. Add `snowflake_default` the same way. |
| Platform values | Available as Airflow Variables: `raw_bucket`, `dms_task_arn`, `glue_crawler`, `kinesis_stream`, `pos_db_secret_id`, `repo_dir`, `dbt_bin`, `generator_python` |
| Re-run or upgrade | `sudo AIRFLOW_VERSION=x.y.z /usr/local/sbin/install_airflow.sh`. The script is idempotent and keeps its keys. Terraform does not re-apply script changes, so the host (and its metadata DB) is never replaced. |

## Cost control

- `enable_dms = false` followed by `make tf-plan tf-apply` removes the replication instance.
- `make ec2-stop` / `make ec2-start` stops and starts the platform host.
- Stop the RDS instance when idle (AWS restarts it automatically after 7 days).
- `make tf-destroy` removes everything except the shared bucket and its data. Never delete `terraform/` in the bucket.
- Set `alert_email` for budget alerts.
