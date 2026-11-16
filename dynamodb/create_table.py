"""Part 3 (Option A) - create the DynamoDB table and its GSI (on-demand billing, no fixed cost).

Item = one order line (no names, emails, or addresses are stored).
    Base table   PK  = CUST#<user_id>
                 SK  = PURCHASE#<purchase_ts>#<order_number>#<sku>
    GSI1         GSI1PK = STYLE#<style_code>           (SKU without color and size)
                 GSI1SK = <purchase_ts>#<order_number>#<sku>

Usage:  python dynamodb/create_table.py
Undo:   aws dynamodb delete-table --table-name hw3-returns-lines
"""
from __future__ import annotations

import boto3

TABLE = "hw3-returns-lines"
REGION = "us-east-1"


def main() -> None:
    ddb = boto3.client("dynamodb", region_name=REGION)
    if TABLE in ddb.list_tables()["TableNames"]:
        print(f"{TABLE} already exists; nothing to do.")
        return
    ddb.create_table(
        TableName=TABLE,
        BillingMode="PAY_PER_REQUEST",
        AttributeDefinitions=[
            {"AttributeName": "PK", "AttributeType": "S"},
            {"AttributeName": "SK", "AttributeType": "S"},
            {"AttributeName": "GSI1PK", "AttributeType": "S"},
            {"AttributeName": "GSI1SK", "AttributeType": "S"},
        ],
        KeySchema=[
            {"AttributeName": "PK", "KeyType": "HASH"},
            {"AttributeName": "SK", "KeyType": "RANGE"},
        ],
        GlobalSecondaryIndexes=[{
            "IndexName": "GSI1",
            "KeySchema": [
                {"AttributeName": "GSI1PK", "KeyType": "HASH"},
                {"AttributeName": "GSI1SK", "KeyType": "RANGE"},
            ],
            # Pattern 3 only needs these, so the index stays small and cheap to write.
            "Projection": {"ProjectionType": "INCLUDE",
                           "NonKeyAttributes": ["sku", "size", "item_quantity", "return_quantity",
                                                "return_reason", "category"]},
        }],
        Tags=[{"Key": "course", "Value": "adsp-31011-hw3"}],
    )
    ddb.get_waiter("table_exists").wait(TableName=TABLE)
    print(f"Created {TABLE} (on-demand) with GSI1.")


if __name__ == "__main__":
    main()
