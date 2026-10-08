#!/usr/bin/env bash
# Platform EC2 host setup (Amazon Linux 2023). Runs from user_data on first boot; re-runnable:
#   sudo /usr/local/sbin/setup_host.sh
# Installs Docker + Compose (Airflow runs as containers, see airflow/docker-compose.yaml) and
# uv (runs the generator), clones the repo to /opt/retail and starts Airflow.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

set -a; source /etc/airflow/infra.env; set +a   # written by Terraform user_data
REPO_DIR=/opt/retail
log() { echo "[setup] $*"; }

log "packages: docker, compose, uv, psql client"
dnf install -y docker git jq postgresql15
systemctl enable --now docker
usermod -aG docker ssm-user 2>/dev/null || true
mkdir -p /usr/local/lib/docker/cli-plugins
[[ -x /usr/local/lib/docker/cli-plugins/docker-compose ]] ||
  curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
command -v uv &>/dev/null ||
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh

# 2 GB swap: five containers + the generator on a 4 GB instance.
if [[ ! -f /swapfile ]]; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo "/swapfile none swap defaults 0 0" >> /etc/fstab
fi

# Terraform values (DB_SECRET_ID, KINESIS_STREAM, RAW_BUCKET, ...) in every login shell.
echo 'set -a; . /etc/airflow/infra.env; set +a' > /etc/profile.d/retail.sh

if [[ ! -d $REPO_DIR/.git ]]; then
  [[ -n "${REPO_URL:-}" ]] || { log "REPO_URL not set: clone the repo to $REPO_DIR and re-run"; exit 0; }
  git clone --branch "${REPO_BRANCH:-main}" "$REPO_URL" $REPO_DIR
fi

log "generator environment (uv sync)"
(cd $REPO_DIR/generators && uv sync --frozen)

log "Airflow (docker compose)"
cd $REPO_DIR/airflow
if [[ ! -f .env ]]; then   # secrets generated once; the Postgres volume depends on them
  ( umask 077; cat > .env <<EOF
AIRFLOW_VERSION=${AIRFLOW_VERSION:-3.3.2}
POSTGRES_PASSWORD=$(openssl rand -hex 16)
AIRFLOW__CORE__FERNET_KEY=$(openssl rand -base64 32 | tr '+/' '-_')
AIRFLOW__API__SECRET_KEY=$(openssl rand -hex 32)
AIRFLOW__API_AUTH__JWT_SECRET=$(openssl rand -hex 32)
EOF
  )
fi
mkdir -p dags logs && chown -R 50000:0 logs
docker compose --env-file .env --env-file /etc/airflow/infra.env up -d

log "done. Airflow UI: make airflow-ui (from your machine). Generator: see README 'Run the generator'."
