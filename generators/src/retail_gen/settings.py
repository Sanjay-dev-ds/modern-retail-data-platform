"""Host settings from /etc/retail/platform.env (written by Terraform user_data, no secrets).

Read from the file rather than the shell environment, so retail-gen works from any shell on the
host. Only the DB credentials are in Secrets Manager (DB_SECRET_ID points at them).
"""

from __future__ import annotations

import os
from pathlib import Path

PLATFORM_ENV = Path(os.environ.get("PLATFORM_ENV", "/etc/retail/platform.env"))


def load_settings() -> dict:
    if not PLATFORM_ENV.is_file():
        raise SystemExit(f"{PLATFORM_ENV} not found: run retail-gen on the platform EC2 host")
    settings = {}
    for line in PLATFORM_ENV.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep and key.strip() and not key.startswith("#"):
            settings[key.strip()] = value.strip()
    os.environ.setdefault("AWS_DEFAULT_REGION", settings.get("AWS_DEFAULT_REGION", "us-east-1"))
    return settings
