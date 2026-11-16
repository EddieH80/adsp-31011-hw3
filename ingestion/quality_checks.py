"""Pre-transformation data-quality checks on raw NOAA records (Assignment 3, Part 1a).

A raw record looks like:
    {"date": "2025-10-01T00:00:00", "datatype": "TMAX", "station": "GHCND:...",
     "attributes": ",,W,2400", "value": 72}

Each check has one job, so a bad record is counted by the check that owns the problem:
  * nulls       - required fields present and non-blank
  * duplicates  - one reading per (station, date, datatype)
  * ranges      - format, expected datatype, plausible value, date inside the requested window

Records a check cannot evaluate (e.g. missing the fields it needs, which `nulls` already
reports) are counted as `skipped`, so passed + failed + skipped always equals the input size.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime
import math

REQUIRED_FIELDS = ("date", "datatype", "station", "value")
DUPLICATE_KEY = ("station", "date", "datatype")
DEFAULT_DATATYPES = frozenset({"PRCP", "SNOW", "TMAX", "TMIN"})

# Plausible daily bounds for units=standard (inches, degrees F). Each is wider than the
# US record, so only impossible values fail: about 43 in of rain and 76 in of snow in one
# day, and about -80 F / 134 F for temperature.
VALUE_BOUNDS = {
    "PRCP": (0.0, 50.0),
    "SNOW": (0.0, 100.0),
    "TMAX": (-100.0, 150.0),
    "TMIN": (-100.0, 150.0),
}


@dataclass
class CheckResult:
    name: str
    passed: int
    failed: int
    failures: list[dict] = field(default_factory=list)  # the failing records, for the quarantine step
    skipped: int = 0                                     # records this check could not evaluate
    details: dict = field(default_factory=dict)          # extra counts worth logging


def _is_blank(record: dict, field_name: str) -> bool:
    value = record.get(field_name)
    return value is None or (isinstance(value, str) and not value.strip())


def _has_fields(record: dict, field_names: tuple[str, ...]) -> bool:
    return not any(_is_blank(record, field_name) for field_name in field_names)


def check_nulls(records: list[dict]) -> CheckResult:
    """Fail records missing a date, datatype, station, or reading value."""
    failures = [record for record in records if not _has_fields(record, REQUIRED_FIELDS)]
    return CheckResult("nulls", len(records) - len(failures), len(failures), failures)


def check_duplicates(records: list[dict]) -> CheckResult:
    """Fail repeated (station, date, datatype) keys.

    Exact copies (every field identical, e.g. a page fetched twice): keep the first,
    fail the rest. Conflicting copies (same key, different content): there is no way to
    know which is right, so every copy fails and goes to quarantine.
    Records missing a key field are skipped; check_nulls reports them.
    """
    groups: dict[tuple, list[int]] = {}
    skipped = 0
    for index, record in enumerate(records):
        if not _has_fields(record, DUPLICATE_KEY):
            skipped += 1
            continue
        key = tuple(record[field_name] for field_name in DUPLICATE_KEY)
        try:
            groups.setdefault(key, []).append(index)
        except TypeError:
            # Malformed, unhashable keys cannot be compared reliably here.
            skipped += 1

    failed_indexes: set[int] = set()
    exact = conflicting = 0
    for indexes in groups.values():
        if len(indexes) < 2:
            continue
        first = records[indexes[0]]
        if all(records[i] == first for i in indexes[1:]):
            failed_indexes.update(indexes[1:])
            exact += len(indexes) - 1
        else:
            failed_indexes.update(indexes)
            conflicting += len(indexes)

    failures = [record for index, record in enumerate(records) if index in failed_indexes]
    evaluated = len(records) - skipped
    return CheckResult(
        "duplicates", evaluated - len(failures), len(failures), failures, skipped,
        {"exact_duplicate_copies": exact, "conflicting_copies": conflicting},
    )


def _parse_date(value: object) -> date | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).date()
    except ValueError:
        return None


def check_ranges(
    records: list[dict],
    expected_datatypes: frozenset[str] | set[str] = DEFAULT_DATATYPES,
    window_start: date | None = None,
    window_end: date | None = None,
) -> CheckResult:
    """Fail bad formats, unexpected datatypes, implausible values, and out-of-window dates.

    Units follow the config (units=standard): inches for PRCP/SNOW, degrees F for TMAX/TMIN.
    Also fails both readings when a station-day has TMAX < TMIN.
    Records missing a required field are skipped; check_nulls reports them.
    """
    failures_by_index: set[int] = set()
    temperatures: dict[tuple[str, date], dict[str, list[tuple[int, float]]]] = {}
    skipped = 0

    for index, record in enumerate(records):
        if not _has_fields(record, REQUIRED_FIELDS):
            skipped += 1
            continue

        parsed_date = _parse_date(record["date"])
        if parsed_date is None:
            failures_by_index.add(index)
        elif (window_start and parsed_date < window_start) or (window_end and parsed_date > window_end):
            failures_by_index.add(index)

        datatype = record["datatype"]
        if datatype not in expected_datatypes or datatype not in VALUE_BOUNDS:
            failures_by_index.add(index)
            continue

        value = record["value"]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            failures_by_index.add(index)
            continue

        low, high = VALUE_BOUNDS[datatype]
        if not low <= value <= high:
            failures_by_index.add(index)

        if datatype in {"TMAX", "TMIN"} and parsed_date is not None:
            temperatures.setdefault((record["station"], parsed_date), {}).setdefault(
                datatype, []
            ).append((index, float(value)))

    for daily_readings in temperatures.values():
        for maximum_index, maximum in daily_readings.get("TMAX", []):
            for minimum_index, minimum in daily_readings.get("TMIN", []):
                if maximum < minimum:
                    failures_by_index.update((maximum_index, minimum_index))

    failures = [record for index, record in enumerate(records) if index in failures_by_index]
    evaluated = len(records) - skipped
    return CheckResult("ranges", evaluated - len(failures), len(failures), failures, skipped)


def run_all(records: list[dict], cfg: dict | None = None) -> list[CheckResult]:
    """Run every check. With cfg, ranges uses the configured datatypes and overall date window."""
    range_args: dict = {}
    if cfg is not None:
        req = cfg["request"]
        range_args = {
            "expected_datatypes": frozenset(req["datatype_ids"]),
            "window_start": date.fromisoformat(min(w["start"] for w in req["date_windows"])),
            "window_end": date.fromisoformat(max(w["end"] for w in req["date_windows"])),
        }
    return [check_nulls(records), check_duplicates(records), check_ranges(records, **range_args)]
