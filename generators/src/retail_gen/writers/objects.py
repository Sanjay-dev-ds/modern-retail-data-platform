"""Object storage for batch files (S3)."""

from __future__ import annotations

from typing import Protocol

import boto3


class ObjectStore(Protocol):
    def put_text(self, key: str, body: str, content_type: str = "text/csv") -> None: ...
    def get_text(self, key: str) -> str: ...
    def list_keys(self, prefix: str) -> list[str]: ...


class S3Store:
    def __init__(self, bucket: str):
        self.bucket = bucket
        self.s3 = boto3.client("s3")

    def put_text(self, key: str, body: str, content_type: str = "text/csv") -> None:
        self.s3.put_object(Bucket=self.bucket, Key=key, Body=body.encode(), ContentType=content_type)

    def get_text(self, key: str) -> str:
        return self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read().decode()

    def list_keys(self, prefix: str) -> list[str]:
        keys = []
        for page in self.s3.get_paginator("list_objects_v2").paginate(Bucket=self.bucket, Prefix=prefix):
            keys.extend(obj["Key"] for obj in page.get("Contents", []))
        return keys

    def __str__(self) -> str:
        return f"s3://{self.bucket}"

