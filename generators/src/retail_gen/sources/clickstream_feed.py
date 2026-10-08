"""Source B: clickstream events to Kinesis (partition key = session_id)."""

from __future__ import annotations

import json
import random

from retail_gen.writers.events import EventSink, Record


def encode(rng: random.Random, events: list[dict], duplicate_rate: float) -> list[Record]:
    """One compact JSON object per record, no trailing newline (Firehose adds it).

    Duplicate defect: some records are sent a second time at the end of the batch, as an
    at-least-once producer retry would.
    """
    records = [(e["session_id"], json.dumps(e, separators=(",", ":")).encode()) for e in events]
    duplicates = [r for r in records if rng.random() < duplicate_rate]
    return records + duplicates


def send(sink: EventSink, rng: random.Random, events: list[dict], duplicate_rate: float) -> int:
    return sink.send(encode(rng, events, duplicate_rate))
