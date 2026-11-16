"""Write raw NOAA pages to the Bronze layer (S3, or a local folder with --local).

Each page is stored unchanged inside an envelope that adds audit metadata:
    {"source_name", "ingested_at", "request": {"url", "params"}, "response": <raw page>}

Keys are deterministic (station + date window + page number), so a rerun overwrites the
same objects instead of creating duplicates. That makes the Bronze load idempotent.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from noaa_client import HERE


def bronze_key(prefix: str, station_id: str, start: str, end: str, page_number: int) -> str:
    safe_station = station_id.replace(":", "_")
    return f"{prefix}/station={safe_station}/window={start}_{end}/page={page_number:04d}.json"


def make_envelope(source_name: str, url: str, params: dict, page: dict) -> dict:
    return {
        "source_name": source_name,
        "ingested_at": datetime.now(timezone.utc).isoformat(),
        "request": {"url": url, "params": params},
        "response": page,
    }


class BronzeWriter:
    def __init__(self, cfg: dict, local: bool):
        b = cfg["bronze"]
        self.prefix = b["s3_prefix"]
        self.local = local
        if local:
            self.root = HERE / b["local_dir"]
        else:
            if b["s3_bucket"] == "CHANGE-ME":
                raise SystemExit("Set bronze.s3_bucket in config.yaml, or run with --local.")
            import boto3  # imported here so --local works without boto3 installed
            self.s3 = boto3.client("s3", region_name=b["aws_region"])
            self.bucket = b["s3_bucket"]

    def write(self, key: str, envelope: dict) -> str:
        body = json.dumps(envelope, indent=None, separators=(",", ":"))
        if self.local:
            path = self.root / key
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
            return str(path)
        self.s3.put_object(Bucket=self.bucket, Key=key, Body=body.encode(), ContentType="application/json")
        return f"s3://{self.bucket}/{key}"
