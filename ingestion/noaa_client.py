"""NOAA CDO v2 client: config, logging, HTTP session, and the request/pagination functions.

Boilerplate (done): load_config, setup_logging, make_session, get_once.
Yours to write (graded in Part 1a): request_with_retry, fetch_all_pages.
"""
from __future__ import annotations

import logging
import os
import threading
import time
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Iterator

import requests
import yaml

log = logging.getLogger("noaa")

HERE = Path(__file__).resolve().parent
_request_lock = threading.Lock()
_last_request_time = 0.0


def load_config(path: str | Path = HERE / "config.yaml") -> dict:
    with open(path) as fh:
        return yaml.safe_load(fh)


def setup_logging(cfg: dict) -> None:
    log_file = HERE / cfg["logging"]["file"]
    log_file.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=cfg["logging"]["level"],
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=[logging.StreamHandler(), logging.FileHandler(log_file)],
    )


def make_session() -> requests.Session:
    """Session with the NOAA token header. The token comes from the NOAA_TOKEN env var only."""
    token = os.environ.get("NOAA_TOKEN")
    if not token:
        raise SystemExit("NOAA_TOKEN is not set. Run: export NOAA_TOKEN=your-token")
    s = requests.Session()
    s.headers.update({"token": token, "Accept": "application/json"})
    return s


def get_once(session: requests.Session, url: str, params: dict, timeout: float) -> requests.Response:
    """One plain GET. No retries, no status checks: request_with_retry() adds those."""
    return session.get(url, params=params, timeout=timeout)


# --------------------------------------------------------------------------------------
# Rate limiting, retries with backoff, and error handling
# --------------------------------------------------------------------------------------
def request_with_retry(session: requests.Session, url: str, params: dict, cfg: dict) -> dict:
    """Return a parsed JSON object, retrying transient failures with rate limiting.

    Retries network errors (timeouts, refused or dropped connections), invalid JSON,
    and HTTP 408, 429, 500, 502, 503, or 504. Other HTTP errors fail immediately.
    A Retry-After header can extend the exponential backoff, up to
    cfg["api"]["max_retry_after_seconds"]; a longer Retry-After gives up instead of
    stalling the run. After exhausting retries, the last request or JSON decoding
    exception is raised. An empty object is a valid response.
    """
    global _last_request_time

    api_cfg = cfg["api"]
    timeout = api_cfg["timeout_seconds"]
    max_retries = api_cfg["max_retries"]
    backoff_base = api_cfg["backoff_base_seconds"]
    max_requests_per_second = api_cfg["max_requests_per_second"]
    max_retry_after = api_cfg["max_retry_after_seconds"]
    if max_requests_per_second <= 0 or max_retries < 0 or backoff_base < 0 or max_retry_after < 0:
        raise ValueError("Request rate must be positive; retries, backoff and Retry-After cap cannot be negative")

    min_request_interval = 1.0 / max_requests_per_second
    retryable_statuses = {408, 429, 500, 502, 503, 504}
    transient_errors = (
        requests.exceptions.Timeout,
        requests.exceptions.ConnectionError,
        requests.exceptions.ChunkedEncodingError,  # connection dropped mid-response
    )

    def wait_before_retry(attempt: int, reason: str, retry_after: float | None = None) -> None:
        """Exponential backoff (base * 2^attempt), extended by Retry-After if the server sent one."""
        delay = backoff_base * (2**attempt)
        if retry_after is not None:
            delay = max(delay, retry_after)
        log.warning(
            "%s; retrying in %.2fs: url=%s params=%s retry=%d/%d",
            reason, delay, url, params, attempt + 1, max_retries,
        )
        time.sleep(delay)

    def retry_after_seconds(response: requests.Response) -> float | None:
        value = response.headers.get("Retry-After")
        if value is None:
            return None
        try:
            return max(0.0, float(value))
        except ValueError:
            try:
                retry_at = parsedate_to_datetime(value)
            except (TypeError, ValueError, OverflowError):
                return None
            if retry_at.tzinfo is None:
                retry_at = retry_at.replace(tzinfo=timezone.utc)
            return max(0.0, (retry_at - datetime.now(timezone.utc)).total_seconds())
    for attempt in range(max_retries + 1):
        with _request_lock:
            elapsed = time.monotonic() - _last_request_time
            rate_limit_wait = max(0.0, min_request_interval - elapsed)
            if rate_limit_wait:
                time.sleep(rate_limit_wait)
            _last_request_time = time.monotonic()

        try:
            response = get_once(session, url, params, timeout)
        except transient_errors as exc:
            if attempt == max_retries:
                log.error(
                    "Request failed after %d attempts: url=%s params=%s error=%s",
                    attempt + 1, url, params, exc,
                )
                raise
            wait_before_retry(attempt, f"Request error ({type(exc).__name__}: {exc})")
            continue

        if response.status_code >= 400:
            if response.status_code not in retryable_statuses:
                log.error(
                    "Non-retryable HTTP failure: url=%s params=%s status=%d",
                    url, params, response.status_code,
                )
                response.raise_for_status()

            if attempt == max_retries:
                log.error(
                    "HTTP request failed after %d attempts: url=%s params=%s status=%d",
                    attempt + 1, url, params, response.status_code,
                )
                response.raise_for_status()

            retry_after = retry_after_seconds(response)
            if retry_after is not None and retry_after > max_retry_after:
                log.error(
                    "Server asked to wait %.0fs (cap %ss); giving up: url=%s params=%s status=%d",
                    retry_after, max_retry_after, url, params, response.status_code,
                )
                response.raise_for_status()

            wait_before_retry(attempt, f"Retryable HTTP failure (status={response.status_code})", retry_after)
            continue

        try:
            payload = response.json()
        except ValueError as exc:
            if attempt == max_retries:
                log.error(
                    "Invalid JSON after %d attempts: url=%s params=%s status=%d error=%s",
                    attempt + 1, url, params, response.status_code, exc,
                )
                raise
            wait_before_retry(attempt, f"Invalid JSON (status={response.status_code}, error={exc})")
            continue

        if not isinstance(payload, dict):
            log.error(
                "Unexpected JSON payload type: url=%s params=%s status=%d type=%s",
                url, params, response.status_code, type(payload).__name__,
            )
            raise ValueError(f"Expected a JSON object from {url}, got {type(payload).__name__}")
        return payload

    raise RuntimeError("Request retry loop ended unexpectedly")


# --------------------------------------------------------------------------------------
# Pagination
# --------------------------------------------------------------------------------------
def fetch_all_pages(session: requests.Session, endpoint: str, params: dict, cfg: dict) -> Iterator[dict]:
    """Yield each raw page (the full JSON dict) for one query, until every record is fetched.

    `endpoint` is a path like "data" or "stations"; build the URL from cfg["api"]["base_url"].
    Use request_with_retry() for every call, and cfg["api"]["page_limit"] as the page size.

    How NOAA pages work (check this against a real response before trusting it):
      * Request params: `limit` (max 1000) and `offset`.
      * Response: {"metadata": {"resultset": {"offset": ..., "count": ..., "limit": ...}},
                   "results": [ ... ]}
      * `count` is the total number of matching records across all pages.
      * Is `offset` 0-based or 1-based? Compare metadata.resultset.offset on your first page
        with what you sent. Getting this wrong silently skips or repeats one record per page.

    Stop when you have everything, and also guard against an endless loop
    (e.g. a page that comes back empty before `count` is reached).

    A query with no matches returns {}: that single empty page is yielded (for the Bronze
    audit trail) and the generator stops. An empty payload after records were already
    fetched is treated as an error.

    Yield the page dict unchanged; run_ingest.py writes each one to Bronze as-is.
    """
    api_cfg = cfg["api"]
    page_limit = api_cfg["page_limit"]
    if not isinstance(page_limit, int) or not 1 <= page_limit <= 1000:
        raise ValueError("page_limit must be an integer between 1 and 1000")

    url = f"{api_cfg['base_url'].rstrip('/')}/{endpoint.lstrip('/')}"
    request_params = dict(params)
    request_params["limit"] = page_limit
    offset = 1
    fetched = 0

    while True:
        request_params["offset"] = offset
        page = request_with_retry(session, url, dict(request_params), cfg)

        # NOAA returns {} (no metadata, no results) when a query matches nothing.
        if not page:
            if fetched == 0:
                # Legitimately empty (e.g. a recent window not published yet). Yield it so
                # Bronze keeps an audit record that the call was made and returned nothing.
                log.info("NOAA returned no data: url=%s params=%s", url, request_params)
                yield page
                return
            log.error(
                "NOAA returned an empty payload mid-pagination: url=%s params=%s fetched=%d",
                url, request_params, fetched,
            )
            raise RuntimeError(f"NOAA pagination stopped with an empty payload after {fetched} records")

        try:
            resultset = page["metadata"]["resultset"]
            count = resultset["count"]
            results = page["results"]
        except (KeyError, TypeError) as exc:
            log.error("Malformed NOAA page: url=%s params=%s", url, request_params)
            raise ValueError("NOAA response is missing pagination metadata or results") from exc

        if not isinstance(count, int) or count < 0 or not isinstance(results, list):
            log.error("Invalid NOAA pagination data: url=%s params=%s count=%r", url, request_params, count)
            raise ValueError("NOAA response count must be a non-negative integer and results must be a list")

        returned_offset = resultset.get("offset")
        if returned_offset is not None and returned_offset != offset:
            log.error(
                "NOAA offset mismatch: url=%s requested_offset=%d returned_offset=%r",
                url, offset, returned_offset,
            )
            raise ValueError(
                f"NOAA returned offset {returned_offset!r} for requested offset {offset}"
            )

        yield page
        fetched += len(results)
        if fetched >= count:
            return
        if not results:
            log.error(
                "NOAA returned an empty page before all records were fetched: "
                "url=%s params=%s fetched=%d count=%d",
                url, request_params, fetched, count,
            )
            raise RuntimeError(f"NOAA pagination stopped at {fetched} of {count} records")

        offset += len(results)
