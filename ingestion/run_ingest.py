"""Run the NOAA -> Bronze ingestion and the pre-transformation quality checks.

Usage (from this folder, with NOAA_TOKEN exported):
    python run_ingest.py --local --stations 1   # quick test: first mapped station, local files
    python run_ingest.py --local                # all stations, local files
    python run_ingest.py                        # all stations, to S3 (set bronze.s3_bucket first)
"""
from __future__ import annotations

import argparse
import csv
import json
import logging

import requests

from bronze_writer import BronzeWriter, bronze_key, make_envelope
from noaa_client import HERE, fetch_all_pages, load_config, make_session, setup_logging
from quality_checks import run_all

log = logging.getLogger("ingest")


def record_failure(st: dict, w: dict, exc: Exception) -> dict:
    """Log one failed station-window and return it for the run summary; the run continues."""
    log.error("Skipping %s (%s, %s) %s..%s after error: %s",
              st["station_id"], st["city"], st["state"], w["start"], w["end"], exc)
    return {"station_id": st["station_id"], "city": st["city"], "window": f"{w['start']}..{w['end']}",
            "error": f"{type(exc).__name__}: {exc}"}


def load_stations(cfg: dict) -> list[dict]:
    with open(HERE / cfg["stations_file"]) as fh:
        rows = list(csv.DictReader(fh))
    mapped = [r for r in rows if r["station_id"].strip()]
    for r in rows:
        if not r["station_id"].strip():
            log.warning("No station_id for %s, %s; skipping (fill stations.csv)", r["city"], r["state"])
    return mapped


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--local", action="store_true", help="write Bronze to ./bronze_local instead of S3")
    ap.add_argument("--stations", type=int, default=None, help="only the first N mapped stations (for testing)")
    args = ap.parse_args()

    cfg = load_config()
    setup_logging(cfg)
    stations = load_stations(cfg)[: args.stations]
    if not stations:
        raise SystemExit("No stations mapped yet. Fill station_id in stations.csv (see find_stations.py).")

    session = make_session()
    writer = BronzeWriter(cfg, local=args.local)
    req = cfg["request"]
    url = f"{cfg['api']['base_url']}/data"
    all_records: list[dict] = []
    failures: list[dict] = []
    pages_written = 0

    for st in stations:
        for w in req["date_windows"]:
            params = {
                "datasetid": req["dataset_id"],
                "stationid": st["station_id"],
                "datatypeid": req["datatype_ids"],  # requests sends a list as repeated params
                "startdate": w["start"],
                "enddate": w["end"],
                "units": req["units"],
            }
            log.info("Fetching %s (%s, %s) %s..%s", st["station_id"], st["city"], st["state"], w["start"], w["end"])
            try:
                for page_number, page in enumerate(fetch_all_pages(session, "data", params, cfg), start=1):
                    key = bronze_key(cfg["bronze"]["s3_prefix"], st["station_id"], w["start"], w["end"], page_number)
                    sent = {**params, "page": page_number, "limit": cfg["api"]["page_limit"],
                            "offset": page.get("metadata", {}).get("resultset", {}).get("offset")}
                    dest = writer.write(key, make_envelope(cfg["source_name"], url, sent, page))
                    pages_written += 1
                    records = page.get("results", [])
                    all_records.extend(records)
                    log.info("  page %d: %d records -> %s", page_number, len(records), dest)
            except requests.HTTPError as exc:
                status = exc.response.status_code if exc.response is not None else None
                if status in (401, 403):
                    # Bad or expired token: every other request would fail the same way.
                    log.error("Authentication failed (HTTP %s); stopping the run. Check NOAA_TOKEN.", status)
                    raise
                failures.append(record_failure(st, w, exc))
            except (requests.RequestException, ValueError, RuntimeError) as exc:
                failures.append(record_failure(st, w, exc))

    log.info("Bronze done: %d pages, %d records, %d failed station-windows", pages_written, len(all_records), len(failures))
    for f in failures:
        log.error("FAILED %s (%s) %s: %s", f["station_id"], f["city"], f["window"], f["error"])

    results = run_all(all_records, cfg)
    report = [{"check": r.name, "passed": r.passed, "failed": r.failed, "skipped": r.skipped, **r.details}
              for r in results]
    for r in results:
        extra = " ".join(f"{k}={v}" for k, v in r.details.items())
        log.info("DQ %-12s passed=%-7d failed=%-6d skipped=%-6d %s", r.name, r.passed, r.failed, r.skipped, extra)
    (HERE / "logs").mkdir(exist_ok=True)
    (HERE / "logs" / "dq_report.json").write_text(json.dumps(report, indent=2))
    (HERE / "logs" / "run_summary.json").write_text(json.dumps(
        {"pages_written": pages_written, "records": len(all_records), "failures": failures}, indent=2))
    if failures:
        raise SystemExit(f"{len(failures)} station-window(s) failed; see logs/run_summary.json")


if __name__ == "__main__":
    main()
