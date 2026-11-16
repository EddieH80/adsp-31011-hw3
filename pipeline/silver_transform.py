"""Part 1b - Silver layer: validate, quarantine, clean, type-cast, mask PII, and join weather.

Reads the Bronze staging tables, runs the data-quality checks, writes failing rows to
silver_quarantine with their reasons, and writes the rest to:
    silver_station_map    city -> NOAA station (from ingestion/stations.csv)
    silver_weather_daily  one row per station per day (PRCP, SNOW, TMAX, TMIN pivoted)
    silver_order_lines    one row per order line, PII masked, weather at purchase/return joined

Every check's pass/fail/skip counts go to etl_dq_log and logs/silver_dq_report.json.

Usage (from HW3/, with RDS_* and PII_HASH_KEY exported):
    python pipeline/silver_transform.py
"""
from __future__ import annotations

import csv
import hashlib
import hmac
import json
import os
import re
from collections import defaultdict

import pandas as pd

from common import INGESTION, DOMAIN_SOURCE_NAME, connect, engine, load_noaa_config, setup_logging, utc_now, write_json
from quality_checks import run_all as run_weather_checks  # Part 1a checks, reused

log = setup_logging("silver")

STATE_CODES = {"Arizona": "AZ", "California": "CA", "Colorado": "CO", "Florida": "FL", "Georgia": "GA",
               "Illinois": "IL", "Massachusetts": "MA", "Maryland": "MD", "Michigan": "MI", "Minnesota": "MN",
               "Missouri": "MO", "North Carolina": "NC", "Nevada": "NV", "New York": "NY", "Ohio": "OH",
               "Oregon": "OR", "Pennsylvania": "PA", "Tennessee": "TN", "Texas": "TX", "Utah": "UT",
               "Washington": "WA"}
PII_COLUMNS = ("customer_name", "customer_email", "shipping_address")
DOMAIN_REQUIRED = ("order_number", "sku", "user_id", "purchase_date", "customer_city", "customer_state",
                   "customer_zip", "loyalty_tier", "warehouse_id", "category", "size", "item_price",
                   "item_quantity", "unit_price_paid", "return_quantity", "lp_review_flag")
AUDIT_COLUMNS = ("bronze_row_id", "source_name", "source_file", "ingested_at")


# ---------------------------------------------------------------- PII masking
def _key() -> bytes:
    key = os.environ.get("PII_HASH_KEY")
    if not key:
        raise SystemExit("Set PII_HASH_KEY first, e.g.: export PII_HASH_KEY=$(openssl rand -hex 32)")
    return key.encode()


def token(value: str | None, key: bytes) -> str:
    """Keyed SHA-256 (HMAC). Same input -> same token, so joins still work; not reversible
    without the key, and unlike a plain hash it can't be brute-forced from a list of names."""
    normalized = (value or "").strip().lower()
    return hmac.new(key, normalized.encode(), hashlib.sha256).hexdigest()


def redact_email(email: str | None) -> str:
    local, _, domain = (email or "").strip().lower().partition("@")
    return f"{local[:1]}***@{domain}" if domain else "***"


def masked_raw(rec: dict, key: bytes) -> dict:
    """A Bronze domain row safe to keep in quarantine: PII replaced by tokens."""
    out = dict(rec)
    for col in PII_COLUMNS:
        if out.get(col) is not None:
            out[col] = "hmac:" + token(out[col], key)[:16]
    return out


# ---------------------------------------------------------------- domain checks
class Check:
    def __init__(self, name: str):
        self.name, self.passed, self.failed, self.skipped = name, 0, 0, 0
        self.reasons: dict[int, str] = {}  # row index -> reason

    def fail(self, idx: int, reason: str) -> None:
        self.reasons.setdefault(idx, reason)

    def finish(self, evaluated: int) -> "Check":
        self.failed = len(self.reasons)
        self.passed = evaluated - self.failed
        return self


def _blank(value) -> bool:
    return value is None or (isinstance(value, float) and value != value) or not str(value).strip()


def _num(value: str | None) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def check_domain(rows: list[dict]) -> list[Check]:
    nulls = Check("nulls")
    for i, r in enumerate(rows):
        missing = [c for c in DOMAIN_REQUIRED if _blank(r.get(c))]
        if missing:
            nulls.fail(i, "missing " + ", ".join(missing))
    nulls.finish(len(rows))

    dups = Check("duplicates")
    groups: dict[tuple, list[int]] = defaultdict(list)
    for i, r in enumerate(rows):
        if not _blank(r.get("order_number")) and not _blank(r.get("sku")):
            groups[(r["order_number"], r["sku"])].append(i)
        else:
            dups.skipped += 1
    content = lambda r: tuple((k, v) for k, v in r.items() if k not in AUDIT_COLUMNS)
    for (order, sku), idxs in groups.items():
        if len(idxs) < 2:
            continue
        first = content(rows[idxs[0]])
        if all(content(rows[j]) == first for j in idxs[1:]):
            for j in idxs[1:]:
                dups.fail(j, f"exact duplicate of bronze row {rows[idxs[0]]['bronze_row_id']}")
        else:
            for j in idxs:
                dups.fail(j, f"conflicting copies of {order}/{sku}")
    dups.finish(len(rows) - dups.skipped)

    ranges = Check("ranges")
    for i, r in enumerate(rows):
        if i in nulls.reasons:
            ranges.skipped += 1
            continue
        purchased = pd.to_datetime(r["purchase_date"], errors="coerce")
        has_return_date = not _blank(r.get("return_date"))
        returned = pd.to_datetime(r["return_date"], errors="coerce") if has_return_date else None
        qty, ret_qty = _num(r["item_quantity"]), _num(r["return_quantity"])
        price, paid = _num(r["item_price"]), _num(r["unit_price_paid"])
        discount = 0.0 if _blank(r.get("discount_pct")) else _num(r["discount_pct"])
        if pd.isna(purchased):
            ranges.fail(i, "purchase_date not a timestamp")
        elif has_return_date and pd.isna(returned):
            ranges.fail(i, "return_date not a timestamp")
        elif returned is not None and returned < purchased:
            ranges.fail(i, "return_date before purchase_date")
        elif qty is None or not (1 <= qty <= 10) or qty != int(qty):
            ranges.fail(i, "item_quantity outside 1..10")
        elif ret_qty is None or not (0 <= ret_qty <= qty):
            ranges.fail(i, "return_quantity outside 0..item_quantity")
        elif ret_qty > 0 and (_blank(r.get("rma")) or not has_return_date):
            ranges.fail(i, "returned line without rma/return_date")
        elif price is None or paid is None or not (0 < paid <= 1000 and 0 < price <= 1000):
            ranges.fail(i, "price outside 0..1000")
        elif discount is None or not (0 <= discount <= 100):
            ranges.fail(i, "discount_pct outside 0..100")
        elif str(r["lp_review_flag"]) not in ("True", "False"):
            ranges.fail(i, "lp_review_flag not boolean")
    ranges.finish(len(rows) - ranges.skipped)
    return [nulls, dups, ranges]


# ---------------------------------------------------------------- cleaning
def weight_in_lb(value: str | None) -> float | None:
    if value is None:
        return None
    m = re.fullmatch(r"\s*([\d.]+)\s*(lb|oz)?\s*", str(value))
    if not m:
        return None
    number = float(m.group(1))
    return round(number / 16, 2) if m.group(2) == "oz" else number


def clean_domain(df: pd.DataFrame, key: bytes) -> pd.DataFrame:
    out = pd.DataFrame()
    out["order_number"] = df.order_number.str.strip()
    out["sku"] = df.sku.str.strip()
    out["user_id"] = df.user_id.str.strip()
    out["purchase_ts"] = pd.to_datetime(df.purchase_date)
    out["purchase_date"] = out.purchase_ts.dt.date
    out["return_ts"] = pd.to_datetime(df.return_date, errors="coerce")
    out["return_date"] = out.return_ts.dt.date.where(out.return_ts.notna(), None)
    out["rma"] = df.rma
    out["customer_name_hash"] = df.customer_name.map(lambda v: token(v, key))
    out["customer_email_hash"] = df.customer_email.map(lambda v: token(v, key))  # lower() fixes casing variants
    out["customer_email_masked"] = df.customer_email.map(redact_email)
    out["customer_city"] = df.customer_city.str.strip()
    out["customer_state"] = df.customer_state.str.strip().map(lambda s: STATE_CODES.get(s, s))
    out["customer_zip3"] = df.customer_zip.str.strip().str.zfill(5).str[:3]
    out["loyalty_tier"] = df.loyalty_tier
    out["customer_profile_size"] = df.customer_profile_size
    out["payment_method"] = df.payment_method
    out["promo_code"] = df.promo_code
    out["discount_pct"] = df.discount_pct.fillna("0").astype(int)
    out["shipping_method"] = df.shipping_method
    out["shipping_cost"] = df.shipping_cost.astype(float)
    out["warehouse_id"] = df.warehouse_id
    out["warehouse_city"] = df.warehouse_city
    out["warehouse_state"] = df.warehouse_state.map(lambda s: STATE_CODES.get(s, s))
    out["style_code"] = out.sku.str.rsplit("-", n=2).str[0]
    out["item_name"] = df.item_name
    out["category"] = df.category
    out["subcategory"] = df.subcategory
    # Brand variants (UPPER, '&' vs 'and', trailing spaces): use each style's most common spelling.
    brand = df.brand.str.strip()
    out["brand"] = brand.groupby(out.style_code).transform(lambda s: s.mode().iloc[0])
    out["color"] = df.color
    out["size"] = df["size"]
    out["item_fit"] = df.item_fit
    out["item_material"] = df.item_material
    out["item_tags"] = df.item_tags
    out["item_weight_lb"] = df.item_weight.map(weight_in_lb)
    # Stale catalog prices on a few rows: conform to each SKU's most common price.
    price = df.item_price.astype(float)
    out["item_price"] = price.groupby(out.sku).transform(lambda s: s.mode().iloc[0])
    out["item_quantity"] = df.item_quantity.astype(int)
    out["unit_price_paid"] = df.unit_price_paid.astype(float)
    out["size_chart_viewed"] = (df.size_chart_viewed == "True").astype(int)
    out["size_switch_count"] = df.size_switch_count.astype(int)
    out["item_rating"] = pd.to_numeric(df.item_rating, errors="coerce").round().astype("Int64")
    out["return_quantity"] = df.return_quantity.astype(int)
    out["return_reason"] = df.return_reason
    comments = df.return_comments.fillna("").str.strip()
    out["return_comments"] = comments.where(comments != "", None)  # whitespace-only -> NULL
    out["item_return_condition"] = df.item_return_condition
    out["refund_method"] = df.refund_method
    out["refund_amount"] = df.refund_amount.fillna("0").astype(float)
    out["inspection_disposition"] = df.inspection_disposition
    out["lp_review_flag"] = (df.lp_review_flag == "True").astype(int)
    return out


# ---------------------------------------------------------------- weather
def build_weather(raw_records: list[dict], cfg: dict) -> tuple[pd.DataFrame, list, list]:
    results = run_weather_checks(raw_records, cfg)
    flagged: dict[int, list[str]] = defaultdict(list)
    for res in results:
        for rec in res.failures:
            flagged[id(rec)].append(res.name)
    good = [r for r in raw_records if id(r) not in flagged]
    bad = [(r, flagged[id(r)]) for r in raw_records if id(r) in flagged]

    w = pd.DataFrame(good)
    w["obs_date"] = pd.to_datetime(w["date"]).dt.date
    w["is_trace"] = w["attributes"].fillna("").str.split(",").str[0].eq("T").astype(int)
    values = w.pivot_table(index=["station", "obs_date"], columns="datatype", values="value", aggfunc="first")
    traces = w.pivot_table(index=["station", "obs_date"], columns="datatype", values="is_trace", aggfunc="max")
    daily = pd.DataFrame(index=values.index)
    daily["prcp_in"] = values.get("PRCP")
    daily["snow_in"] = values.get("SNOW")
    daily["tmax_f"] = values.get("TMAX").round().astype("Int64")
    daily["tmin_f"] = values.get("TMIN").round().astype("Int64")
    daily["prcp_is_trace"] = traces.get("PRCP").fillna(0).astype(int)
    daily["snow_is_trace"] = traces.get("SNOW").fillna(0).astype(int) if "SNOW" in traces else 0
    daily = daily.reset_index().rename(columns={"station": "station_id"})
    return daily, results, bad


def load_station_map(cfg: dict) -> pd.DataFrame:
    with open(INGESTION / cfg["stations_file"]) as fh:
        return pd.DataFrame(list(csv.DictReader(fh)))[["city", "state", "role", "station_id", "station_name"]]


def enrich(lines: pd.DataFrame, stations: pd.DataFrame, weather: pd.DataFrame) -> pd.DataFrame:
    cust = stations[stations.role.isin(["customer", "both"])][["city", "state", "station_id"]]
    out = lines.merge(cust, how="left", left_on=["customer_city", "customer_state"], right_on=["city", "state"])
    out = out.drop(columns=["city", "state"])
    cols = ["prcp_in", "snow_in", "tmax_f", "tmin_f"]
    for when in ("purchase", "return"):
        wx = weather[["station_id", "obs_date"] + cols].rename(
            columns={"obs_date": f"{when}_date", **{c: f"{when}_{c}" for c in cols}})
        out = out.merge(wx, how="left", on=["station_id", f"{when}_date"])
    return out


# ---------------------------------------------------------------- main
def write(conn, eng, table: str, df: pd.DataFrame) -> None:
    with conn.cursor() as cur:
        cur.execute(f"DELETE FROM {table}")
    df.to_sql(table, eng, if_exists="append", index=False, chunksize=1000, method="multi")
    log.info("%s: %d rows", table, len(df))


def main() -> None:
    key = _key()
    cfg = load_noaa_config()
    run_id, now = utc_now().replace(" ", "T"), utc_now()
    conn, eng = connect(), engine()

    domain = pd.read_sql("SELECT * FROM bronze_returns_lines ORDER BY bronze_row_id", eng, dtype=str)
    domain = domain.astype(object).where(domain.notna(), None)
    noaa = pd.read_sql("SELECT bronze_id, raw_record FROM bronze_noaa_records ORDER BY bronze_id", eng)
    log.info("Bronze read: %d domain rows, %d NOAA records", len(domain), len(noaa))

    # Quality checks before any transformation
    rows = domain.to_dict("records")
    domain_checks = check_domain(rows)
    noaa_records = [json.loads(r) for r in noaa.raw_record]
    weather, weather_checks, weather_bad = build_weather(noaa_records, cfg)

    report, quarantine = [], []
    for c in domain_checks:
        report.append({"source": DOMAIN_SOURCE_NAME, "check": c.name, "passed": c.passed,
                       "failed": c.failed, "skipped": c.skipped})
    for c in weather_checks:
        report.append({"source": cfg["source_name"], "check": c.name, "passed": c.passed,
                       "failed": c.failed, "skipped": c.skipped, **c.details})

    failed_idx: dict[int, list[tuple[str, str]]] = defaultdict(list)
    for c in domain_checks:
        for i, reason in c.reasons.items():
            failed_idx[i].append((c.name, reason))
    for i, problems in failed_idx.items():
        r = rows[i]
        quarantine.append({"source_name": DOMAIN_SOURCE_NAME, "check_name": problems[0][0],
                           "reason": "; ".join(p[1] for p in problems)[:255],
                           "record_key": f"{r.get('order_number')}/{r.get('sku')} (bronze row {r['bronze_row_id']})",
                           "raw_record": json.dumps(masked_raw(r, key), default=str), "quarantined_at": now})
    for rec, checks in weather_bad:
        quarantine.append({"source_name": cfg["source_name"], "check_name": checks[0],
                           "reason": "failed " + ", ".join(checks),
                           "record_key": f"{rec.get('station')}/{rec.get('date')}/{rec.get('datatype')}",
                           "raw_record": json.dumps(rec), "quarantined_at": now})

    passing = domain.drop(index=list(failed_idx)).reset_index(drop=True)
    lines = clean_domain(passing, key)
    stations = load_station_map(cfg)
    lines = enrich(lines, stations, weather)
    lines["silver_loaded_at"] = now
    unmatched = int(lines.station_id.isna().sum())
    no_purchase_wx = int(lines.purchase_tmax_f.isna().sum())

    write(conn, eng, "silver_station_map", stations)
    write(conn, eng, "silver_weather_daily", weather)
    write(conn, eng, "silver_order_lines", lines)
    write(conn, eng, "silver_quarantine", pd.DataFrame(quarantine))
    dq_log = pd.DataFrame([{"run_id": run_id, "layer": "silver", "source_name": r["source"],
                            "check_name": r["check"], "passed": r["passed"], "failed": r["failed"],
                            "skipped": r["skipped"], "logged_at": now} for r in report])
    dq_log.to_sql("etl_dq_log", eng, if_exists="append", index=False)

    summary = {"run_id": run_id, "checks": report,
               "quarantined": {"domain": len(failed_idx), "noaa": len(weather_bad)},
               "silver_rows": {"silver_order_lines": len(lines), "silver_weather_daily": len(weather),
                               "silver_station_map": len(stations)},
               "lines_without_station": unmatched, "lines_without_purchase_weather": no_purchase_wx}
    write_json("silver_dq_report.json", summary)
    for r in report:
        log.info("DQ %-28s %-10s passed=%-6d failed=%-4d skipped=%d", r["source"], r["check"],
                 r["passed"], r["failed"], r["skipped"])
    log.info("Quarantined: %s | lines without purchase-day weather: %d", summary["quarantined"], no_purchase_wx)
    conn.close()


if __name__ == "__main__":
    main()
