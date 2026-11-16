"""Part 3 access patterns (P1-P3) and Part 4b NoSQL showcase queries (B1-B3), with boto3.

Every call is a Query or GetItem on a key - no Scan. Each prints the items DynamoDB read
(ScannedCount), the items returned (Count), and the read capacity it consumed.

Usage:  python dynamodb/queries.py                  # all six, with the demo IDs below
        python dynamodb/queries.py --customer U104402 --style NL-JEA-1036
"""
from __future__ import annotations

import argparse
from collections import Counter

import boto3
from boto3.dynamodb.conditions import Attr, Key

from create_table import REGION, TABLE

WINDOW_START, WINDOW_END = "2026-07-01", "2026-09-30"
END = WINDOW_END + "T23:59:59~"   # '~' sorts after every character used in the key


def query_all(table, paginate: bool = True, **kwargs) -> tuple[list[dict], dict]:
    """Query and follow LastEvaluatedKey, so results over 1 MB still come back complete.
    paginate=False makes exactly one call (used with Limit, e.g. "latest 5")."""
    items, stats = [], {"Count": 0, "ScannedCount": 0, "RCU": 0.0, "calls": 0}
    kwargs["ReturnConsumedCapacity"] = "TOTAL"
    while True:
        resp = table.query(**kwargs)
        items += resp["Items"]
        stats["Count"] += resp["Count"]
        stats["ScannedCount"] += resp["ScannedCount"]
        stats["RCU"] += resp["ConsumedCapacity"]["CapacityUnits"]
        stats["calls"] += 1
        if not paginate or "LastEvaluatedKey" not in resp:
            return items, stats
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]


def header(title: str, code: str) -> None:
    print("\n" + "=" * 78 + f"\n{title}\n" + "-" * 78 + f"\n{code.strip()}\n" + "-" * 78)


def show_stats(stats: dict) -> None:
    print(f"[read {stats['ScannedCount']} items, returned {stats['Count']}, "
          f"{stats['calls']} call(s), {stats['RCU']} RCU]")


def p1_most_common_size(table, customer: str) -> None:
    header(f"P1  Most common size bought by {customer}, {WINDOW_START}..{WINDOW_END} (excluding OS)",
           f"""table.query(
    KeyConditionExpression=Key("PK").eq("CUST#{customer}")
        & Key("SK").between("PURCHASE#{WINDOW_START}", "PURCHASE#{END}"),
    ProjectionExpression="#s, item_quantity", ExpressionAttributeNames={{"#s": "size"}})""")
    items, stats = query_all(
        table,
        KeyConditionExpression=Key("PK").eq(f"CUST#{customer}")
        & Key("SK").between(f"PURCHASE#{WINDOW_START}", f"PURCHASE#{END}"),
        ProjectionExpression="#s, item_quantity", ExpressionAttributeNames={"#s": "size"})
    sizes = Counter()
    for it in items:
        if it["size"] != "OS":
            sizes[it["size"]] += int(it["item_quantity"])
    print(f"Units by size: {dict(sizes.most_common())}")
    print(f"Checkout size prompt -> {sizes.most_common(1)[0][0] if sizes else 'no history'}")
    show_stats(stats)


def p2_customer_return_rate(table, customer: str) -> None:
    header(f"P2  Return rate across all purchases for {customer}",
           f"""table.query(
    KeyConditionExpression=Key("PK").eq("CUST#{customer}") & Key("SK").begins_with("PURCHASE#"),
    ProjectionExpression="item_quantity, return_quantity, refund_amount")""")
    items, stats = query_all(
        table,
        KeyConditionExpression=Key("PK").eq(f"CUST#{customer}") & Key("SK").begins_with("PURCHASE#"),
        ProjectionExpression="item_quantity, return_quantity, refund_amount")
    bought = sum(int(i["item_quantity"]) for i in items)
    returned = sum(int(i["return_quantity"]) for i in items)
    refunds = sum(float(i["refund_amount"]) for i in items)
    print(f"{len(items)} order lines | units bought {bought} | units returned {returned} | "
          f"return rate {100 * returned / bought:.1f}% | refunds ${refunds:,.2f}")
    show_stats(stats)


def p3_style_return_rate(table, style: str) -> None:
    header(f"P3  Return rate for style {style}, bought {WINDOW_START}..{WINDOW_END} (GSI1)",
           f"""table.query(IndexName="GSI1",
    KeyConditionExpression=Key("GSI1PK").eq("STYLE#{style}")
        & Key("GSI1SK").between("{WINDOW_START}", "{END}"))""")
    items, stats = query_all(
        table, IndexName="GSI1",
        KeyConditionExpression=Key("GSI1PK").eq(f"STYLE#{style}")
        & Key("GSI1SK").between(WINDOW_START, END))
    by_size: dict[str, list[int]] = {}
    for it in items:
        b = by_size.setdefault(it["size"], [0, 0])
        b[0] += int(it["item_quantity"]); b[1] += int(it["return_quantity"])
    bought = sum(v[0] for v in by_size.values()); returned = sum(v[1] for v in by_size.values())
    print(f"Style return rate: {returned}/{bought} units = {100 * returned / bought:.1f}%")
    for size, (b, r) in sorted(by_size.items(), key=lambda kv: -kv[1][1] / kv[1][0]):
        print(f"   size {size:<4} {r:>3}/{b:<3} returned = {100 * r / b:5.1f}%")
    show_stats(stats)


def b1_latest_purchases(table, customer: str) -> None:
    header(f"B1  The 5 most recent order lines for {customer} (newest first, one call)",
           f"""table.query(
    KeyConditionExpression=Key("PK").eq("CUST#{customer}") & Key("SK").begins_with("PURCHASE#"),
    ScanIndexForward=False, Limit=5)""")
    items, stats = query_all(
        table, KeyConditionExpression=Key("PK").eq(f"CUST#{customer}") & Key("SK").begins_with("PURCHASE#"),
        ScanIndexForward=False, Limit=5, paginate=False)
    for it in items[:5]:
        status = f"returned ({it['return_reason']})" if "return_ts" in it else "kept"
        print(f"   {it['purchase_ts']}  {it['order_number']}  {it['sku']:<20} x{it['item_quantity']}  {status}")
    show_stats(stats)


def b2_recent_returns(table, customer: str) -> None:
    header(f"B2  Lines {customer} bought {WINDOW_START}..{WINDOW_END} and sent back (key range + filter)",
           f"""table.query(
    KeyConditionExpression=Key("PK").eq("CUST#{customer}")
        & Key("SK").between("PURCHASE#{WINDOW_START}", "PURCHASE#{END}"),
    FilterExpression=Attr("return_quantity").gt(0))""")
    items, stats = query_all(
        table,
        KeyConditionExpression=Key("PK").eq(f"CUST#{customer}")
        & Key("SK").between(f"PURCHASE#{WINDOW_START}", f"PURCHASE#{END}"),
        FilterExpression=Attr("return_quantity").gt(0))
    for it in items:
        print(f"   bought {it['purchase_ts'][:10]}  returned {it['return_ts'][:10]}  {it['sku']:<20} "
              f"{it['return_reason']:<26} refund ${float(it['refund_amount']):.2f}  LP flag={it['lp_review_flag']}")
    print("(The filter runs after the key range is read, so ScannedCount > Count.)")
    show_stats(stats)


def b3_get_one_line(table, customer: str) -> None:
    latest, _ = query_all(table, KeyConditionExpression=Key("PK").eq(f"CUST#{customer}"),
                          ScanIndexForward=False, Limit=1, paginate=False,
                          ProjectionExpression="PK, SK")
    pk, sk = latest[0]["PK"], latest[0]["SK"]
    header("B3  Customer service: fetch one exact order line by its full key (GetItem)",
           f"""table.get_item(Key={{"PK": "{pk}", "SK": "{sk}"}}, ConsistentRead=True)""")
    resp = table.get_item(Key={"PK": pk, "SK": sk}, ConsistentRead=True, ReturnConsumedCapacity="TOTAL")
    for k, v in sorted(resp["Item"].items()):
        print(f"   {k:<16} {v}")
    print(f"[1 item, {resp['ConsumedCapacity']['CapacityUnits']} RCU, strongly consistent]")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--customer", default="U100718")
    ap.add_argument("--style", default="NL-DRE-1055")
    a = ap.parse_args()
    table = boto3.resource("dynamodb", region_name=REGION).Table(TABLE)
    p1_most_common_size(table, a.customer)
    p2_customer_return_rate(table, a.customer)
    p3_style_return_rate(table, a.style)
    b1_latest_purchases(table, a.customer)
    b2_recent_returns(table, a.customer)
    b3_get_one_line(table, a.customer)


if __name__ == "__main__":
    main()
