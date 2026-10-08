"""Command line: `retail-gen seed` and `retail-gen run`. Runs on the platform EC2 host.

Environment (from /etc/airflow/infra.env, loaded in login shells):
  DB_SECRET_ID    Secrets Manager secret with the POS database credentials
  KINESIS_STREAM  clickstream stream name
  RAW_BUCKET      landing bucket for catalog files
"""

from __future__ import annotations

import argparse
import logging
import os

from retail_gen import runner
from retail_gen.config import load_config
from retail_gen.writers.events import KinesisSink
from retail_gen.writers.objects import S3Store


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} is not set. Run on the platform host in a login shell (bash -l).")
    return value


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="retail-gen", description=__doc__.splitlines()[0])
    parser.add_argument("--config", help="YAML config (default: generators/config/default.yaml)")
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    p_seed = sub.add_parser("seed", help="load POS history and catalog snapshots (once, before DMS)")
    p_seed.add_argument("--force", action="store_true",
                        help="truncate POS tables and reload (only before DMS is started)")

    p_run = sub.add_parser("run", help="live loop: sales, CDC changes, clickstream, daily catalog")
    p_run.add_argument("--once", action="store_true", help="run a single cycle and exit")

    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    logging.getLogger("botocore").setLevel(logging.WARNING)

    cfg = load_config(args.config)
    _require("DB_SECRET_ID")
    sinks = runner.Sinks(objects=S3Store(_require("RAW_BUCKET")),
                         events=KinesisSink(_require("KINESIS_STREAM")))

    if args.command == "seed":
        runner.seed(cfg, sinks, force=args.force)
    else:
        runner.run(cfg, sinks, once=args.once)


if __name__ == "__main__":
    main()
