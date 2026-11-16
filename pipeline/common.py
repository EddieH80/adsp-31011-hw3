"""Shared helpers for the Assignment 3 pipeline: config, logging, S3, MySQL, and SQL files.

Secrets never live in files:
    RDS password    - read at connect time from the RDS-managed secret in AWS Secrets Manager
                      (or from RDS_HOST / RDS_USER / RDS_PASSWORD if those are exported)
    PII_HASH_KEY    - secret key for HMAC-SHA256 masking (Silver step), from the environment
"""
from __future__ import annotations

import json
import logging
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import pymysql
import yaml
from sqlalchemy import create_engine
from sqlalchemy.engine import URL

HW3 = Path(__file__).resolve().parents[1]
INGESTION = HW3 / "ingestion"
SQL_DIR = HW3 / "sql"
LOG_DIR = HW3 / "logs"
DOMAIN_CSV = HW3.parent / "HW2" / "apparel_returns_flat.csv"
DATABASE = "returns_dw"

DOMAIN_SOURCE_NAME = "northloom_apparel_returns_a2"
DOMAIN_BRONZE_PREFIX = "bronze/northloom/apparel_returns_flat"

sys.path.insert(0, str(INGESTION))  # reuse quality_checks.py from Part 1a


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def load_noaa_config() -> dict:
    with open(INGESTION / "config.yaml") as fh:
        return yaml.safe_load(fh)


def setup_logging(name: str) -> logging.Logger:
    LOG_DIR.mkdir(exist_ok=True)
    logging.basicConfig(
        level="INFO",
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=[logging.StreamHandler(), logging.FileHandler(LOG_DIR / "pipeline.log")],
    )
    return logging.getLogger(name)


def _env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Set {name} in your shell first (see the README / chat instructions).")
    return value


RDS_INSTANCE = "adsp-31011-hw3-dw"
_creds: dict | None = None


def rds_credentials() -> dict:
    """Host, user, password. Uses RDS_HOST/RDS_USER/RDS_PASSWORD if set; otherwise looks up the
    instance endpoint and reads the RDS-managed master secret from Secrets Manager.
    The password is held in memory only and never printed or written anywhere."""
    global _creds
    if _creds is None:
        if os.environ.get("RDS_PASSWORD"):
            _creds = {"host": _env("RDS_HOST"), "user": _env("RDS_USER"), "password": os.environ["RDS_PASSWORD"]}
        else:
            import boto3
            rds = boto3.client("rds", region_name="us-east-1")
            db = rds.describe_db_instances(DBInstanceIdentifier=RDS_INSTANCE)["DBInstances"][0]
            secret = boto3.client("secretsmanager", region_name="us-east-1").get_secret_value(
                SecretId=db["MasterUserSecret"]["SecretArn"])
            value = json.loads(secret["SecretString"])
            _creds = {"host": db["Endpoint"]["Address"], "user": value["username"], "password": value["password"]}
    return _creds


def connect(database: str | None = DATABASE) -> pymysql.connections.Connection:
    c = rds_credentials()
    return pymysql.connect(
        host=c["host"], user=c["user"], password=c["password"],
        database=database, port=3306, charset="utf8mb4", autocommit=True,
        local_infile=False, connect_timeout=15,
    )


def engine():
    c = rds_credentials()
    url = URL.create("mysql+pymysql", username=c["user"], password=c["password"],
                     host=c["host"], port=3306, database=DATABASE, query={"charset": "utf8mb4"})
    return create_engine(url, pool_pre_ping=True)


def split_sql(text: str) -> list[str]:
    """Split a .sql file into statements. Drops `--` comment lines; statements end with `;`."""
    lines = [ln for ln in text.splitlines() if not ln.strip().startswith("--")]
    return [s.strip() for s in "\n".join(lines).split(";") if s.strip()]


def run_sql_file(conn, path: Path, log: logging.Logger, show_results: bool = False) -> list:
    """Execute every statement in a .sql file. Returns (statement, rows) for SELECTs."""
    results = []
    with conn.cursor() as cur:
        for stmt in split_sql(path.read_text()):
            cur.execute(stmt)
            if cur.description:
                rows = cur.fetchall()
                cols = [d[0] for d in cur.description]
                results.append((stmt, cols, rows))
                if show_results:
                    print("\n" + re.sub(r"\s+", " ", stmt)[:160])
                    print(" | ".join(cols))
                    for row in rows[:40]:
                        print(" | ".join("" if v is None else str(v) for v in row))
    log.info("Ran %s", path.name)
    return results


def write_json(name: str, payload) -> Path:
    LOG_DIR.mkdir(exist_ok=True)
    path = LOG_DIR / name
    path.write_text(json.dumps(payload, indent=2, default=str))
    return path
