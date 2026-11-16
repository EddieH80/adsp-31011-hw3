"""Part 1b - Bronze layer.

1. Lands the Assignment 2 domain file in S3 unchanged (next to the NOAA pages from Part 1a),
   with source_name / ingested_at as S3 object metadata plus a small manifest file.
2. Creates the Bronze/Silver staging tables (sql/01_medallion_ddl.sql).
3. Copies both Bronze sources into MySQL staging tables with zero destructive transformation:
   every domain value stays a string, every NOAA record stays its original JSON.

Usage (from HW3/, with RDS_HOST / RDS_USER / RDS_PASSWORD exported):
    python pipeline/bronze_load.py
"""
from __future__ import annotations

import csv
import io
import json

import boto3

from common import (DOMAIN_BRONZE_PREFIX, DOMAIN_CSV, DOMAIN_SOURCE_NAME, SQL_DIR, connect,
                    load_noaa_config, run_sql_file, setup_logging, utc_now, write_json)

log = setup_logging("bronze")
BATCH = 2000


def land_domain_file_in_s3(s3, bucket: str, ingested_at: str) -> str:
    """Upload the raw CSV byte-for-byte. The key is fixed per ingest date, so reruns overwrite."""
    day = ingested_at[:10]
    key = f"{DOMAIN_BRONZE_PREFIX}/ingest_date={day}/{DOMAIN_CSV.name}"
    s3.upload_file(str(DOMAIN_CSV), bucket, key, ExtraArgs={
        "ContentType": "text/csv",
        "Metadata": {"source_name": DOMAIN_SOURCE_NAME, "ingested_at": ingested_at}})
    manifest = {"source_name": DOMAIN_SOURCE_NAME, "ingested_at": ingested_at,
                "source_file": DOMAIN_CSV.name, "bytes": DOMAIN_CSV.stat().st_size}
    s3.put_object(Bucket=bucket, Key=f"{DOMAIN_BRONZE_PREFIX}/ingest_date={day}/_manifest.json",
                  Body=json.dumps(manifest).encode(), ContentType="application/json")
    log.info("Landed s3://%s/%s", bucket, key)
    return key


def load_domain_rows(conn, s3, bucket: str, key: str, ingested_at: str) -> int:
    """Read the file back from S3 (Bronze is the source of truth) and insert every row as text."""
    body = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")
    reader = csv.DictReader(io.StringIO(body))
    cols = reader.fieldnames
    sql = (f"INSERT INTO bronze_returns_lines (bronze_row_id, {', '.join(cols)}, source_name, source_file, ingested_at) "
           f"VALUES ({', '.join(['%s'] * (len(cols) + 4))})")
    source_file = f"s3://{bucket}/{key}"
    rows, total = [], 0
    with conn.cursor() as cur:
        for line_no, rec in enumerate(reader, start=2):  # line 1 is the header
            # Empty CSV cells become NULL; every other value is kept exactly as written.
            rows.append([line_no] + [rec[c] if rec[c] != "" else None for c in cols]
                        + [DOMAIN_SOURCE_NAME, source_file, ingested_at])
            if len(rows) == BATCH:
                cur.executemany(sql, rows); total += len(rows); rows = []
        if rows:
            cur.executemany(sql, rows); total += len(rows)
    log.info("bronze_returns_lines: %d rows", total)
    return total


def load_noaa_records(conn, s3, cfg: dict) -> tuple[int, int]:
    bucket, prefix = cfg["bronze"]["s3_bucket"], cfg["bronze"]["s3_prefix"]
    sql = ("INSERT INTO bronze_noaa_records (raw_record, s3_key, source_name, ingested_at) "
           "VALUES (%s, %s, %s, %s)")
    pages = records = 0
    paginator = s3.get_paginator("list_objects_v2")
    with conn.cursor() as cur:
        for listing in paginator.paginate(Bucket=bucket, Prefix=prefix + "/"):
            for obj in listing.get("Contents", []):
                env = json.loads(s3.get_object(Bucket=bucket, Key=obj["Key"])["Body"].read())
                pulled = env["ingested_at"][:19].replace("T", " ")
                results = (env.get("response") or {}).get("results", [])
                cur.executemany(sql, [(json.dumps(r), obj["Key"], env["source_name"], pulled) for r in results])
                pages += 1
                records += len(results)
    log.info("bronze_noaa_records: %d records from %d pages", records, pages)
    return pages, records


def main() -> None:
    cfg = load_noaa_config()
    bucket = cfg["bronze"]["s3_bucket"]
    s3 = boto3.client("s3", region_name=cfg["bronze"]["aws_region"])
    ingested_at = utc_now()

    key = land_domain_file_in_s3(s3, bucket, ingested_at)
    conn = connect()
    run_sql_file(conn, SQL_DIR / "01_medallion_ddl.sql", log)  # recreates staging tables: rerun-safe
    domain_rows = load_domain_rows(conn, s3, bucket, key, ingested_at)
    pages, noaa_records = load_noaa_records(conn, s3, cfg)
    write_json("bronze_summary.json", {"ingested_at": ingested_at, "domain_s3_key": key,
                                       "bronze_returns_lines": domain_rows,
                                       "noaa_pages": pages, "bronze_noaa_records": noaa_records})
    conn.close()


if __name__ == "__main__":
    main()
