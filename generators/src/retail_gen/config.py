"""Generator settings, loaded from generators/config/default.yaml (or --config)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from pathlib import Path

import yaml

DEFAULT_CONFIG = Path(__file__).resolve().parents[2] / "config" / "default.yaml"


@dataclass(frozen=True)
class Scale:
    stores: int
    skus: int
    customers: int
    history_days: int
    transactions_per_day: int
    avg_lines_per_transaction: float


@dataclass(frozen=True)
class Mix:
    online_share: float
    anonymous_share: float
    split_payment_rate: float


@dataclass(frozen=True)
class Mutations:
    void_rate: float
    return_rate: float
    delete_rate: float
    tier_change_rate: float
    store_change_rate: float


@dataclass(frozen=True)
class CatalogChanges:
    price_change_rate: float
    new_skus_per_day: int
    discontinue_rate: float


@dataclass(frozen=True)
class Defects:
    duplicate_events: float
    late_arriving: float
    null_values: float
    invalid_values: float
    orphan_sku: float
    payment_mismatch: float
    schema_drift_day: date | None


@dataclass(frozen=True)
class Targets:
    clickstream_events_per_second: float
    incremental_cycle_seconds: int


@dataclass(frozen=True)
class Config:
    seed: int
    scale: Scale
    mix: Mix
    mutations: Mutations
    catalog: CatalogChanges
    defects: Defects
    targets: Targets


def load_config(path: str | Path | None = None) -> Config:
    raw = yaml.safe_load(Path(path or DEFAULT_CONFIG).read_text())
    defects = dict(raw["defects"])
    drift = defects.get("schema_drift_day")
    # YAML parses unquoted dates as date objects; quoted ones arrive as strings.
    defects["schema_drift_day"] = date.fromisoformat(drift) if isinstance(drift, str) else drift
    return Config(
        seed=raw["seed"],
        scale=Scale(**raw["scale"]),
        mix=Mix(**raw["mix"]),
        mutations=Mutations(**raw["mutations"]),
        catalog=CatalogChanges(**raw["catalog"]),
        defects=Defects(**defects),
        targets=Targets(**raw["targets"]),
    )
