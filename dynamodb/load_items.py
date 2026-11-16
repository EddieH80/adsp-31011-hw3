"""Part 3 (Option A) - load order lines from the Silver layer (RDS) into DynamoDB.

Reads silver_order_lines (already cleaned and PII-masked), keeps only what the access
patterns need, and writes one item per order line with batch_writer (25 items per request,
automatic retries of unprocessed items). Also saves 12 example items for the report.

Usage (from HW3/, with RDS_* exported):
    python dynamodb/load_items.py            # all Silver lines (~29.8k items, a few cents)
    python dynamodb/load_items.py --limit 500
"""
from __future__ import annotations

import argparse
import csv
import sys
from decimal import Decimal
from pathlib import Path

import boto3

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
from common import LOG_DIR, connect  # noqa: E402

from create_table import REGION, TABLE  # noqa: E402

QUERY = """
SELECT user_id, order_number, sku, style_code, size, category, item_name, loyalty_tier,
       DATE_FORMAT(purchase_ts, '%Y-%m-%dT%H:%i:%s') AS purchase_ts,
       DATE_FORMAT(return_ts,   '%Y-%m-%dT%H:%i:%s') AS return_ts,
       item_quantity, unit_price_paid, return_quantity, return_reason, refund_amount, lp_review_flag
FROM silver_order_lines
ORDER BY user_id, purchase_ts, order_number, sku
"""


def to_item(r: dict) -> dict:
    line = f"{r['purchase_ts']}#{r['order_number']}#{r['sku']}"
    item = {
        "PK": f"CUST#{r['user_id']}",
        "SK": f"PURCHASE#{line}",
        "GSI1PK": f"STYLE#{r['style_code']}",
        "GSI1SK": line,
        "entity_type": "ORDER_LINE",
        "user_id": r["user_id"],
        "order_number": r["order_number"],
        "sku": r["sku"],
        "style_code": r["style_code"],
        "size": r["size"],
        "category": r["category"],
        "item_name": r["item_name"],
        "loyalty_tier": r["loyalty_tier"],
        "purchase_ts": r["purchase_ts"],
        "item_quantity": int(r["item_quantity"]),
        "unit_price_paid": Decimal(str(r["unit_price_paid"])),
        "return_quantity": int(r["return_quantity"]),
        "refund_amount": Decimal(str(r["refund_amount"])),
        "lp_review_flag": bool(r["lp_review_flag"]),
    }
    if r["return_ts"]:            # attributes are optional in DynamoDB: omit instead of storing NULL
        item["return_ts"] = r["return_ts"]
        item["return_reason"] = r["return_reason"]
    return item


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=None)
    args = ap.parse_args()

    conn = connect()
    with conn.cursor() as cur:
        cur.execute(QUERY)
        cols = [d[0] for d in cur.description]
        rows = [dict(zip(cols, row)) for row in cur.fetchall()]
    conn.close()
    rows = rows[: args.limit] if args.limit else rows

    table = boto3.resource("dynamodb", region_name=REGION).Table(TABLE)
    with table.batch_writer(overwrite_by_pkeys=["PK", "SK"]) as batch:
        for i, r in enumerate(rows, start=1):
            batch.put_item(Item=to_item(r))
            if i % 5000 == 0:
                print(f"  {i:,} items written")
    print(f"Loaded {len(rows):,} items into {TABLE}")

    # Example items for the report: two customers' lines plus some returned lines.
    demo = [r for r in rows if r["user_id"] == "U100718"][:6] + [r for r in rows if r["return_ts"]][:6]
    LOG_DIR.mkdir(exist_ok=True)
    with open(LOG_DIR / "dynamodb_item_examples.csv", "w", newline="") as fh:
        fields = ["PK", "SK", "GSI1PK", "GSI1SK", "size", "category", "item_quantity",
                  "return_quantity", "return_reason"]
        w = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in demo:
            w.writerow(to_item(r))
    print(f"Saved {len(demo)} example items to logs/dynamodb_item_examples.csv")


if __name__ == "__main__":
    main()
