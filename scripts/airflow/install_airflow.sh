#!/usr/bin/env bash
# Set up the platform EC2 host (Amazon Linux 2023): Apache Airflow 3 plus the generator runtime.
#
# Layout:
#   /opt/airflow                 AIRFLOW_HOME (logs, generated UI passwords)
#   /opt/airflow/venv            Airflow + providers (amazon, postgres, snowflake)
#   /opt/airflow/dbt-venv        dbt-snowflake, kept apart to avoid dependency clashes
#   /opt/airflow/gen-venv        synthetic data generators (generators/requirements.txt)
#   /opt/retail                  repo checkout; DAGs are read from /opt/retail/airflow/dags
#   /etc/airflow/infra.env       values from Terraform (written by EC2 user_data)
#   /etc/airflow/airflow.env     Airflow config (regenerated on every run)
#   /etc/airflow/secrets.env     Fernet key, JWT/API secrets, metadata DB password (kept across runs)
#   /etc/profile.d/retail.sh     DB_SECRET_ID, KINESIS_STREAM, RAW_BUCKET for interactive shells
#
# Metadata DB is a local PostgreSQL 15. Executor is LocalExecutor.
# Services (systemd): airflow-api-server, airflow-scheduler, airflow-dag-processor, airflow-triggerer.
# The UI binds to 127.0.0.1:8080; reach it through SSM port forwarding (make airflow-ui).
#
# Safe to re-run (e.g. to upgrade AIRFLOW_VERSION): secrets are preserved and `airflow db migrate`
# is idempotent. Run as root:  sudo bash scripts/airflow/install_airflow.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
cd /tmp   # service users cannot read /root

# Terraform-provided values (optional when running by hand)
if [[ -f /etc/airflow/infra.env ]]; then
  set -a; source /etc/airflow/infra.env; set +a
fi

AIRFLOW_VERSION="${AIRFLOW_VERSION:-3.3.2}"
PYTHON_VERSION="3.11"
AIRFLOW_USER="airflow"
AIRFLOW_HOME="/opt/airflow"
VENV="$AIRFLOW_HOME/venv"
DBT_VENV="$AIRFLOW_HOME/dbt-venv"
GEN_VENV="$AIRFLOW_HOME/gen-venv"
INSTALL_DBT="${INSTALL_DBT:-true}"
REPO_DIR="${REPO_DIR:-/opt/retail}"
REPO_URL="${REPO_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-main}"
DAGS_FOLDER="${DAGS_FOLDER:-$REPO_DIR/airflow/dags}"
SECRETS_PREFIX="${SECRETS_PREFIX:-}"          # e.g. retail-data-platform-dev/airflow
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-14}"
SWAP_MB="${SWAP_MB:-2048}"
CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

log() { echo "[install_airflow] $*"; }

# ---------------------------------------------------------------- OS packages
log "installing OS packages"
dnf install -y \
  "python${PYTHON_VERSION}" "python${PYTHON_VERSION}-pip" "python${PYTHON_VERSION}-devel" \
  gcc git jq openssl postgresql15 postgresql15-server

# Swap gives pip and the four Airflow processes headroom on a 4 GB instance.
if [[ "$SWAP_MB" -gt 0 && ! -f /swapfile ]]; then
  log "creating ${SWAP_MB} MB swap"
  dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap defaults 0 0" >> /etc/fstab
fi

# ---------------------------------------------------------------- service user and dirs
if ! id "$AIRFLOW_USER" &>/dev/null; then
  useradd --system --home-dir "$AIRFLOW_HOME" --shell /bin/bash "$AIRFLOW_USER"
fi
mkdir -p "$AIRFLOW_HOME" /etc/airflow "$REPO_DIR"
chown "$AIRFLOW_USER:$AIRFLOW_USER" "$AIRFLOW_HOME" "$REPO_DIR"

# ---------------------------------------------------------------- secrets (generated once)
SECRETS_FILE=/etc/airflow/secrets.env
if [[ ! -f "$SECRETS_FILE" ]]; then
  log "generating secrets"
  umask 077
  cat > "$SECRETS_FILE" <<EOF
AIRFLOW_DB_PASSWORD=$(openssl rand -hex 24)
AIRFLOW__CORE__FERNET_KEY=$(openssl rand -base64 32 | tr '+/' '-_')
AIRFLOW__API__SECRET_KEY=$(openssl rand -hex 32)
AIRFLOW__API_AUTH__JWT_SECRET=$(openssl rand -hex 32)
EOF
  umask 022
fi
chown root:"$AIRFLOW_USER" "$SECRETS_FILE"
chmod 640 "$SECRETS_FILE"
# shellcheck disable=SC1090
source "$SECRETS_FILE"

# ---------------------------------------------------------------- metadata DB (local PostgreSQL)
if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
  log "initialising PostgreSQL"
  postgresql-setup --initdb
fi

# Peer auth for the postgres OS user, password auth for TCP on localhost only.
cat > /var/lib/pgsql/data/pg_hba.conf <<'EOF'
local   all   postgres                 peer
local   all   all                      scram-sha-256
host    all   all   127.0.0.1/32       scram-sha-256
host    all   all   ::1/128            scram-sha-256
EOF
chown postgres:postgres /var/lib/pgsql/data/pg_hba.conf
systemctl enable --now postgresql
systemctl reload postgresql

log "creating airflow role and database"
sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'airflow') THEN
    CREATE ROLE airflow LOGIN;
  END IF;
END
\$\$;
ALTER ROLE airflow PASSWORD '${AIRFLOW_DB_PASSWORD}';
EOF
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = 'airflow'" | grep -q 1; then
  sudo -u postgres createdb -O airflow airflow
fi

# ---------------------------------------------------------------- Python environments
log "installing Airflow ${AIRFLOW_VERSION}"
sudo -u "$AIRFLOW_USER" bash -euo pipefail <<EOF
[[ -x "$VENV/bin/python" ]] || "python${PYTHON_VERSION}" -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip wheel
"$VENV/bin/pip" install --quiet \
  "apache-airflow[postgres,amazon,snowflake]==${AIRFLOW_VERSION}" \
  --constraint "$CONSTRAINTS_URL"
EOF

if [[ "$INSTALL_DBT" == "true" ]]; then
  log "installing dbt-snowflake"
  sudo -u "$AIRFLOW_USER" bash -euo pipefail <<EOF
[[ -x "$DBT_VENV/bin/python" ]] || "python${PYTHON_VERSION}" -m venv "$DBT_VENV"
"$DBT_VENV/bin/pip" install --quiet --upgrade pip wheel
"$DBT_VENV/bin/pip" install --quiet --upgrade dbt-snowflake
EOF
fi

# ---------------------------------------------------------------- DAG source
if [[ -n "$REPO_URL" && ! -d "$REPO_DIR/.git" ]]; then
  log "cloning $REPO_URL"
  sudo -u "$AIRFLOW_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
fi
sudo -u "$AIRFLOW_USER" mkdir -p "$DAGS_FOLDER"

# ---------------------------------------------------------------- generators
# Separate venv so generator dependencies never fight Airflow's constraints. Skipped until the
# repo (with generators/requirements.txt) is on the host; re-run the script after cloning.
GEN_REQS="$REPO_DIR/generators/requirements.txt"
if [[ -f "$GEN_REQS" ]]; then
  log "installing generator requirements"
  sudo -u "$AIRFLOW_USER" bash -euo pipefail <<EOF
[[ -x "$GEN_VENV/bin/python" ]] || "python${PYTHON_VERSION}" -m venv "$GEN_VENV"
"$GEN_VENV/bin/pip" install --quiet --upgrade pip wheel
"$GEN_VENV/bin/pip" install --quiet -r "$GEN_REQS"
EOF
else
  log "skipping generators: $GEN_REQS not found"
fi

# Environment for interactive shells (scripts/init_db.sh, running generators by hand).
cat > /etc/profile.d/retail.sh <<EOF
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
export DB_SECRET_ID=${DB_SECRET_ID:-}
export KINESIS_STREAM=${KINESIS_STREAM:-}
export RAW_BUCKET=${RAW_BUCKET:-}
EOF

# ---------------------------------------------------------------- Airflow config
log "writing /etc/airflow/airflow.env"
SECRETS_BACKEND_LINES=""
if [[ -n "$SECRETS_PREFIX" ]]; then
  # Connections/variables are looked up in Secrets Manager under <prefix>/connections/<id>
  # and <prefix>/variables/<key> before falling back to env vars and the metadata DB.
  SECRETS_BACKEND_LINES="AIRFLOW__SECRETS__BACKEND=airflow.providers.amazon.aws.secrets.secrets_manager.SecretsManagerBackend
AIRFLOW__SECRETS__BACKEND_KWARGS='{\"connections_prefix\": \"${SECRETS_PREFIX}/connections\", \"variables_prefix\": \"${SECRETS_PREFIX}/variables\"}'"
fi

cat > /etc/airflow/airflow.env <<EOF
# Generated by scripts/airflow/install_airflow.sh. Edit the script, not this file.
AIRFLOW_HOME=${AIRFLOW_HOME}
PATH=${VENV}/bin:/usr/local/bin:/usr/bin:/bin
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}

AIRFLOW__CORE__EXECUTOR=LocalExecutor
AIRFLOW__CORE__PARALLELISM=8
AIRFLOW__CORE__DAGS_FOLDER=${DAGS_FOLDER}
AIRFLOW__CORE__LOAD_EXAMPLES=False
AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION=True
AIRFLOW__CORE__DEFAULT_TIMEZONE=utc
AIRFLOW__CORE__EXECUTION_API_SERVER_URL=http://127.0.0.1:8080/execution/
AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_USERS=admin:admin
AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_PASSWORDS_FILE=${AIRFLOW_HOME}/simple_auth_manager_passwords.json.generated
AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:${AIRFLOW_DB_PASSWORD}@127.0.0.1:5432/airflow
AIRFLOW__API__BASE_URL=http://localhost:8080
AIRFLOW__DAG_PROCESSOR__REFRESH_INTERVAL=60
${SECRETS_BACKEND_LINES}

# Platform values exposed to DAGs as Airflow Variables (Variable.get("raw_bucket"), ...)
AIRFLOW_VAR_RAW_BUCKET=${RAW_BUCKET:-}
AIRFLOW_VAR_DMS_TASK_ARN=${DMS_TASK_ARN:-}
AIRFLOW_VAR_GLUE_CRAWLER=${GLUE_CRAWLER:-}
AIRFLOW_VAR_KINESIS_STREAM=${KINESIS_STREAM:-}
AIRFLOW_VAR_POS_DB_SECRET_ID=${DB_SECRET_ID:-}
AIRFLOW_VAR_REPO_DIR=${REPO_DIR}
AIRFLOW_VAR_DBT_BIN=${DBT_VENV}/bin/dbt
AIRFLOW_VAR_GENERATOR_PYTHON=${GEN_VENV}/bin/python
EOF
chown root:"$AIRFLOW_USER" /etc/airflow/airflow.env
chmod 640 /etc/airflow/airflow.env   # contains the metadata DB password

# CLI wrapper: `airflow-cli dags list` runs as the airflow user with the service environment.
cat > /usr/local/bin/airflow-cli <<'EOF'
#!/usr/bin/env bash
exec sudo -u airflow bash -c 'set -a; source /etc/airflow/airflow.env; source /etc/airflow/secrets.env; set +a; cd /opt/airflow; exec airflow "$@"' airflow-cli "$@"
EOF
chmod 755 /usr/local/bin/airflow-cli

log "migrating metadata database"
airflow-cli db migrate

# ---------------------------------------------------------------- systemd services
declare -A SERVICES=(
  [api-server]="api-server --host 127.0.0.1 --port 8080 --workers 2"
  [scheduler]="scheduler"
  [dag-processor]="dag-processor"
  [triggerer]="triggerer"
)

for name in "${!SERVICES[@]}"; do
  cat > "/etc/systemd/system/airflow-${name}.service" <<EOF
[Unit]
Description=Airflow ${name}
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
User=${AIRFLOW_USER}
Group=${AIRFLOW_USER}
WorkingDirectory=${AIRFLOW_HOME}
EnvironmentFile=/etc/airflow/airflow.env
EnvironmentFile=/etc/airflow/secrets.env
ExecStart=${VENV}/bin/airflow ${SERVICES[$name]}
Restart=always
RestartSec=10
KillMode=mixed
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
done

# Airflow does not prune task logs; remove old ones daily.
cat > /etc/systemd/system/airflow-log-cleanup.service <<EOF
[Unit]
Description=Delete Airflow logs older than ${LOG_RETENTION_DAYS} days

[Service]
Type=oneshot
User=${AIRFLOW_USER}
ExecStart=/usr/bin/find ${AIRFLOW_HOME}/logs -type f -mtime +${LOG_RETENTION_DAYS} -delete
ExecStart=/usr/bin/find ${AIRFLOW_HOME}/logs -mindepth 1 -type d -empty -delete
EOF
cat > /etc/systemd/system/airflow-log-cleanup.timer <<'EOF'
[Unit]
Description=Daily Airflow log cleanup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now airflow-log-cleanup.timer
for name in "${!SERVICES[@]}"; do
  systemctl enable "airflow-${name}"
  systemctl restart "airflow-${name}"
done

log "done. Airflow ${AIRFLOW_VERSION} is running."
log "UI login: user 'admin', password in ${AIRFLOW_HOME}/simple_auth_manager_passwords.json.generated (created on first api-server start)"
log "DAGs folder: ${DAGS_FOLDER}"
