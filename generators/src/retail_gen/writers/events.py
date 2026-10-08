"""Event sink for clickstream records (Kinesis)."""

from __future__ import annotations

import logging
import time
from typing import Protocol

import boto3

log = logging.getLogger(__name__)

Record = tuple[str, bytes]  # (partition key, payload)

KINESIS_MAX_RECORDS = 500
KINESIS_MAX_BYTES = 5 * 1024 * 1024


class EventSink(Protocol):
    def send(self, records: list[Record]) -> int: ...


class KinesisSink:
    def __init__(self, stream_name: str):
        self.stream_name = stream_name
        self.kinesis = boto3.client("kinesis")

    def send(self, records: list[Record]) -> int:
        sent = 0
        batch: list[Record] = []
        size = 0
        for record in records:
            record_size = len(record[0]) + len(record[1])
            if batch and (len(batch) == KINESIS_MAX_RECORDS or size + record_size > KINESIS_MAX_BYTES):
                sent += self._put(batch)
                batch, size = [], 0
            batch.append(record)
            size += record_size
        if batch:
            sent += self._put(batch)
        return sent

    def _put(self, batch: list[Record], attempts: int = 5) -> int:
        """PutRecords is partial-success: retry only the records that failed."""
        pending = batch
        for attempt in range(attempts):
            resp = self.kinesis.put_records(
                StreamName=self.stream_name,
                Records=[{"PartitionKey": key, "Data": data} for key, data in pending],
            )
            if resp["FailedRecordCount"] == 0:
                return len(batch)
            pending = [rec for rec, res in zip(pending, resp["Records"]) if "ErrorCode" in res]
            log.warning("retrying %d throttled/failed records", len(pending))
            time.sleep(0.2 * 2**attempt)
        raise RuntimeError(f"{len(pending)} records still failing after {attempts} attempts")

    def __str__(self) -> str:
        return f"kinesis://{self.stream_name}"

