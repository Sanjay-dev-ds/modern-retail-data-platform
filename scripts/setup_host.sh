#!/usr/bin/env bash
# Platform EC2 host setup (Amazon Linux 2023). Runs from user_data on first boot; re-runnable:
#   sudo /usr/local/sbin/setup_host.sh
# Installs Docker + Compose (Airflow runs as containers, see airflow/docker-compose.yaml) and
# uv (runs the generator), clones the repo to /opt/retail and starts Airflow.
# Settings come from /etc/retail/platform.env (written by Terraform user_data, no secrets).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

PLATFORM_ENV=/etc/retail/platform.env
set -a; source $PLATFORM_ENV; set +a
REPO_DIR=/opt/retail
log() { echo "[setup] $*"; }

log "packages: docker, compose, uv, psql client"
dnf install -y docker git jq postgresql15
systemctl enable --now docker
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

# Convenience for interactive shells ($RAW_BUCKET, $DMS_TASK_ARN in README commands).
# The tools read $PLATFORM_ENV themselves.
echo "set -a; . $PLATFORM_ENV; set +a" > /etc/profile.d/retail.sh

if [[ ! -d $REPO_DIR/.git ]]; then
  git clone --branch "$REPO_BRANCH" "$REPO_URL" $REPO_DIR
fi

log "generator environment (uv sync)"
(cd $REPO_DIR/generators && uv sync --frozen)

log "Airflow (docker compose)"
cd $REPO_DIR/airflow
cp $PLATFORM_ENV .env   # compose reads ${VAR}s from .env in this directory
mkdir -p dags logs && chown -R 50000:0 logs
docker compose up -d

log "done. Airflow UI: make airflow-ui (from your machine). Generator: see README 'Run the generator on EC2'."
