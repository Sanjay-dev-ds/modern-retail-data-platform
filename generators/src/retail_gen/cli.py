"""Command line: `retail-gen seed` and `retail-gen run`. Runs on the platform EC2 host.

Settings (bucket, Kinesis stream, DB secret name) come from /etc/retail/platform.env,
so it works from any shell on the host without exported variables.
"""

from __future__ import annotations

import argparse
import logging

from retail_gen import runner
from retail_gen.config import load_config
from retail_gen.settings import load_settings
from retail_gen.writers.events import KinesisSink
from retail_gen.writers.objects import S3Store


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
    settings = load_settings()
    sinks = runner.Sinks(
        objects=S3Store(settings["RAW_BUCKET"]),
        events=KinesisSink(settings["KINESIS_STREAM"]),
        db_secret_id=settings["DB_SECRET_ID"],
    )

    if args.command == "seed":
        runner.seed(cfg, sinks, force=args.force)
    else:
        runner.run(cfg, sinks, once=args.once)


if __name__ == "__main__":
    main()
