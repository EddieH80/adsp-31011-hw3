"""Helper: list candidate GHCND stations for each city in stations.csv, so you can pick one.

It uses your fetch_all_pages() and request_with_retry().

Usage (with NOAA_TOKEN exported):
    python find_stations.py                          # all cities without a station_id yet
    python find_stations.py Denver CO                # one city
    python find_stations.py Kansas City MO           # multi-word cities work without quotes
    python find_stations.py Denver CO --top 25       # look further down the list (default 10)
    python find_stations.py Detroit MI --airports    # only stations named like an airport

For each candidate it measures how many days of PRCP and SNOW the station actually has in
the first date window (one request per measurement, reading only NOAA's `count`). That is
more useful than NOAA's `datacoverage`, which covers the station's whole history.
Candidates are sorted by those in-window counts. Pick one with PRCP and SNOW close to the
window length, then copy its id and name into stations.csv.
"""
from __future__ import annotations

import csv
import re
import sys
from datetime import date

from noaa_client import HERE, fetch_all_pages, load_config, make_session, request_with_retry, setup_logging

AIRPORT_WORDS = ("AIRPORT", " AP", "INTL", "INTERNATIONAL")


def norm(s: str) -> str:
    return re.sub(r"[^a-z ]", "", s.lower()).strip()


def parse_args(argv: list[str]) -> tuple[list[str], int, bool]:
    words, top, airports_only = [], 10, False
    i = 0
    while i < len(argv):
        if argv[i] == "--top":
            if i + 1 >= len(argv) or not argv[i + 1].isdigit():
                raise SystemExit("--top needs a number, e.g. --top 25")
            top = int(argv[i + 1])
            i += 2
            continue
        if argv[i] == "--airports":
            airports_only = True
        else:
            words.append(argv[i])
        i += 1
    return words, top, airports_only


def days_with_data(session, cfg: dict, station_id: str, datatype: str, start: str, end: str) -> int:
    """Number of records (= days) a station has for one datatype in [start, end]."""
    page = request_with_retry(session, f"{cfg['api']['base_url']}/data", {
        "datasetid": cfg["request"]["dataset_id"], "stationid": station_id, "datatypeid": datatype,
        "startdate": start, "enddate": end, "limit": 1}, cfg)
    return page.get("metadata", {}).get("resultset", {}).get("count", 0) if page else 0


def main() -> None:
    cfg = load_config()
    setup_logging(cfg)
    req = cfg["request"]
    words, top, airports_only = parse_args(sys.argv[1:])
    start, end = req["date_windows"][0]["start"], req["date_windows"][-1]["end"]
    w_start, w_end = req["date_windows"][0]["start"], req["date_windows"][0]["end"]
    window_days = (date.fromisoformat(w_end) - date.fromisoformat(w_start)).days + 1

    if len(words) >= 2:
        # Last word is the state; everything before it is the city.
        wanted = [{"city": " ".join(words[:-1]), "state": words[-1].upper()}]
    elif len(words) == 1:
        raise SystemExit("Give a city and a state, e.g.: python find_stations.py Kansas City MO")
    else:
        with open(HERE / cfg["stations_file"]) as fh:
            wanted = [r for r in csv.DictReader(fh) if not r["station_id"].strip()]
        if not wanted:
            raise SystemExit("Every city in stations.csv already has a station_id. "
                             "To look one up again, name it: python find_stations.py Kansas City MO")

    session = make_session()
    print(f"Looking up: {', '.join(w['city'] + ' ' + w['state'] for w in wanted)} (loading NOAA city list...)")

    # NOAA names city locations like "Denver, CO US". Check a few names in the output if matches fail.
    cities = [loc for page in fetch_all_pages(session, "locations",
                                              {"locationcategoryid": "CITY", "datasetid": req["dataset_id"]}, cfg)
              for loc in page.get("results", [])]
    print(f"{len(cities)} NOAA city locations loaded\n")

    for w in wanted:
        target = norm(w["city"])
        match = [c for c in cities
                 if norm(c["name"].split(",")[0]) == target and f", {w['state']} " in c["name"] + " "]
        if not match:
            print(f"{w['city']}, {w['state']}: no NOAA city location found; search https://www.ncei.noaa.gov/cdo-web/search\n")
            continue
        loc = match[0]
        stations = [s for page in fetch_all_pages(session, "stations", {
            "datasetid": req["dataset_id"], "locationid": loc["id"], "datatypeid": "TMAX",
            "startdate": start, "enddate": end}, cfg) for s in page.get("results", [])]
        if airports_only:
            stations = [s for s in stations if any(word in (s.get("name") or "").upper() for word in AIRPORT_WORDS)]
        # Airports (USW) first, then by NOAA's coverage, to choose which candidates to measure.
        stations.sort(key=lambda s: (not s["id"].startswith("GHCND:USW"), -s.get("datacoverage", 0)))
        candidates = stations[:top]

        print(f"{w['city']}, {w['state']}  ({loc['id']}: {len(stations)} stations with TMAX"
              f"{', airport names only' if airports_only else ''}; measuring {len(candidates)}...)")
        measured = []
        for s in candidates:
            prcp = days_with_data(session, cfg, s["id"], "PRCP", w_start, w_end)
            snow = days_with_data(session, cfg, s["id"], "SNOW", w_start, w_end)
            measured.append((prcp, snow, s))
        measured.sort(key=lambda m: (m[0] + m[1], m[2]["id"].startswith("GHCND:USW")), reverse=True)

        print(f"    {'station':<20} {'PRCP':>5} {'SNOW':>5}  (days of {window_days}, {w_start}..{w_end})  last date  name")
        for prcp, snow, s in measured:
            print(f"    {s['id']:<20} {prcp:>5} {snow:>5}  {'':>36}{s.get('maxdate', '')[:10]}  {s.get('name')}")
        print()


if __name__ == "__main__":
    main()
