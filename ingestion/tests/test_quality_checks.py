"""Tests for quality_checks.py. Run from the ingestion folder:  python -m pytest -q

One example test is included. Add your own for check_duplicates and check_ranges,
including edge cases (e.g. value == 0, a missing key vs. a None value).
"""
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quality_checks import check_duplicates, check_nulls, check_ranges, run_all  # noqa: E402

GOOD = {"date": "2025-10-01T00:00:00", "datatype": "TMAX", "station": "GHCND:TEST0001", "attributes": ",,W,", "value": 72}


def test_check_nulls_flags_missing_value():
    records = [GOOD, {**GOOD, "value": None}]
    result = check_nulls(records)
    assert (result.passed, result.failed) == (1, 1)
    assert result.failures == [{**GOOD, "value": None}]


def test_check_nulls_flags_missing_and_blank_required_fields_but_accepts_zero():
    missing_station = {key: value for key, value in GOOD.items() if key != "station"}
    blank_datatype = {**GOOD, "datatype": "  "}
    zero_value = {**GOOD, "value": 0}
    result = check_nulls([missing_station, blank_datatype, zero_value])
    assert (result.passed, result.failed) == (1, 2)


def test_check_duplicates_quarantines_all_copies_when_values_conflict():
    conflicting = {**GOOD, "value": 80}
    different_datatype = {**GOOD, "datatype": "TMIN"}
    different_station = {**GOOD, "station": "GHCND:OTHER"}
    result = check_duplicates([GOOD, conflicting, different_datatype, different_station])
    assert (result.passed, result.failed) == (2, 2)
    assert result.failures == [GOOD, conflicting]
    assert result.details == {"exact_duplicate_copies": 0, "conflicting_copies": 2}


def test_check_duplicates_keeps_first_of_exact_copies():
    result = check_duplicates([GOOD, dict(GOOD), dict(GOOD)])
    assert (result.passed, result.failed) == (1, 2)
    assert result.details == {"exact_duplicate_copies": 2, "conflicting_copies": 0}


def test_check_duplicates_skips_records_with_missing_key_fields():
    missing_station = {key: value for key, value in GOOD.items() if key != "station"}
    result = check_duplicates([missing_station, missing_station.copy()])
    assert (result.passed, result.failed, result.skipped) == (0, 0, 2)


def test_check_ranges_accepts_zero_and_flags_negative_values_and_bad_dates():
    zero = {**GOOD, "datatype": "PRCP", "value": 0}
    negative = {**GOOD, "datatype": "SNOW", "value": -0.1}
    bad_date = {**GOOD, "date": "not-a-date"}
    result = check_ranges([zero, negative, bad_date])
    assert (result.passed, result.failed) == (1, 2)
    assert result.failures == [negative, bad_date]


def test_check_ranges_checks_temperature_bounds_and_daily_order():
    maximum = {**GOOD, "datatype": "TMAX", "value": 40}
    minimum = {**GOOD, "datatype": "TMIN", "value": 45}
    out_of_bounds = {**GOOD, "value": 151}
    result = check_ranges([maximum, minimum, out_of_bounds])
    assert (result.passed, result.failed) == (0, 3)
    assert result.failures == [maximum, minimum, out_of_bounds]


def test_check_ranges_rejects_non_numeric_and_non_finite_values():
    non_numeric = {**GOOD, "value": "72"}
    not_finite = {**GOOD, "value": float("inf")}
    result = check_ranges([non_numeric, not_finite])
    assert (result.passed, result.failed) == (0, 2)


def test_check_ranges_allows_equal_daily_max_and_min():
    maximum = {**GOOD, "datatype": "TMAX", "value": 50}
    minimum = {**GOOD, "datatype": "TMIN", "value": 50}
    assert check_ranges([maximum, minimum]).failed == 0


def test_check_ranges_rejects_unexpected_datatype():
    result = check_ranges([{**GOOD, "datatype": "AWND", "value": 9}])
    assert (result.passed, result.failed) == (0, 1)


def test_check_ranges_enforces_upper_bounds_for_precipitation_and_snow():
    heavy_rain = {**GOOD, "datatype": "PRCP", "value": 49.9}
    impossible_rain = {**GOOD, "datatype": "PRCP", "value": 500}
    impossible_snow = {**GOOD, "datatype": "SNOW", "value": 101}
    result = check_ranges([heavy_rain, impossible_rain, impossible_snow])
    assert result.failures == [impossible_rain, impossible_snow]


def test_check_ranges_rejects_dates_outside_the_window():
    inside = {**GOOD, "date": "2026-11-14T00:00:00"}
    before = {**GOOD, "date": "2025-09-30T00:00:00"}
    after = {**GOOD, "date": "2031-01-01T00:00:00"}
    result = check_ranges([inside, before, after], window_start=date(2025, 10, 1), window_end=date(2026, 11, 14))
    assert result.failures == [before, after]


def test_each_problem_is_counted_by_one_check_only():
    missing_station = {key: value for key, value in GOOD.items() if key != "station"}
    no_value = {**GOOD, "value": None}
    records = [GOOD, missing_station, no_value]
    nulls, duplicates, ranges = run_all(records)
    assert nulls.failed == 2
    assert ranges.failed == 0 and ranges.skipped == 2
    for result in (nulls, duplicates, ranges):
        assert result.passed + result.failed + result.skipped == len(records)


def test_run_all_uses_config_window_and_datatypes():
    cfg = {"request": {"datatype_ids": ["PRCP"], "date_windows": [
        {"start": "2025-10-01", "end": "2026-09-30"}, {"start": "2026-10-01", "end": "2026-11-14"}]}}
    late = {**GOOD, "datatype": "PRCP", "value": 0.1, "date": "2026-11-15T00:00:00"}
    tmax_not_requested = {**GOOD}
    ranges = run_all([late, tmax_not_requested], cfg)[2]
    assert ranges.failures == [late, tmax_not_requested]
