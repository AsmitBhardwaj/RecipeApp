"""Stock photos for generated budget-plan meals (Pexels).

`search_dish_photo(query)` looks one dish up on Pexels; `fetch_photos(queries)`
does a batch concurrently under a total time budget. Photos are a nicety: every
failure path (no key, timeout, HTTP error, bad payload, rate cap) returns None and
is logged — it must never fail or delay a plan beyond the batch budget.

Results are cached in the `photo_cache` table by normalized query, so a repeated
dish makes no API call. A "no result" is cached too, but expires after
`config.PHOTO_NEGATIVE_CACHE_DAYS` so a transient miss isn't remembered forever.
A rolling in-process hourly counter caps live Pexels calls
(`config.PEXELS_MAX_CALLS_PER_HOUR`, default 150 — under the free tier's 200).
"""
from __future__ import annotations

import json
import logging
import re
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor, wait
from datetime import datetime, timedelta, timezone
from typing import Deque, List, Optional, Sequence

import requests

from .. import config, db

_log = logging.getLogger("uvicorn.error")

PEXELS_SEARCH_URL = "https://api.pexels.com/v1/search"
REQUEST_TIMEOUT_SECONDS = 3
BATCH_BUDGET_SECONDS = 4.0
MAX_PARALLEL = 7
NONE_MARKER = "none"

_calls: Deque[float] = deque()
_calls_lock = threading.Lock()


def normalize_query(query: str) -> str:
    return re.sub(r"\s+", " ", (query or "").strip().lower())


def _under_hourly_cap() -> bool:
    """Record one call against the rolling hour; False (and log) if over the cap."""
    now = time.monotonic()
    with _calls_lock:
        while _calls and now - _calls[0] > 3600:
            _calls.popleft()
        if len(_calls) >= config.PEXELS_MAX_CALLS_PER_HOUR:
            _log.warning("pexels hourly call cap reached (%d); skipping photo", len(_calls))
            return False
        _calls.append(now)
        return True


def reset_rate_counter() -> None:
    """Test hook."""
    with _calls_lock:
        _calls.clear()


def _cached(key: str) -> tuple[bool, Optional[dict]]:
    """(hit, result). A fresh negative entry is a hit with result None."""
    row = db.get_photo_cache(key)
    if row is None:
        return False, None
    if row["result_json"] == NONE_MARKER:
        try:
            created = datetime.fromisoformat(row["created_at"])
        except ValueError:
            return False, None
        if datetime.now(timezone.utc) - created > timedelta(days=config.PHOTO_NEGATIVE_CACHE_DAYS):
            return False, None
        return True, None
    try:
        return True, json.loads(row["result_json"])
    except ValueError:
        return False, None


def _store(key: str, result: Optional[dict]) -> None:
    db.save_photo_cache(
        key,
        json.dumps(result) if result else NONE_MARKER,
        datetime.now(timezone.utc).isoformat(),
    )


def search_dish_photo(query: str) -> Optional[dict]:
    """{image_url, photographer, photographer_url, pexels_url} for the dish, or None."""
    if not config.PEXELS_API_KEY:
        return None
    key = normalize_query(query)
    if not key:
        return None
    try:
        hit, cached = _cached(key)
        if hit:
            return cached
        if not _under_hourly_cap():
            return None
        resp = requests.get(
            PEXELS_SEARCH_URL,
            params={"query": key, "per_page": 5, "orientation": "landscape", "size": "medium"},
            headers={"Authorization": config.PEXELS_API_KEY},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        resp.raise_for_status()
        photos = resp.json().get("photos") or []
        result: Optional[dict] = None
        if photos:
            first = photos[0]
            result = {
                "image_url": first["src"]["large"],
                "photographer": first.get("photographer"),
                "photographer_url": first.get("photographer_url"),
                "pexels_url": first.get("url"),
            }
        _store(key, result)
        return result
    except Exception as exc:  # noqa: BLE001 - photos must never fail a plan
        _log.warning("plan photo lookup failed for %r: %s", query, exc)
        return None


def fetch_photos(queries: Sequence[str]) -> List[Optional[dict]]:
    """Look up every query concurrently (≤ MAX_PARALLEL at once); any lookup not
    finished within BATCH_BUDGET_SECONDS is abandoned as None. Order is preserved."""
    if not queries or not config.PEXELS_API_KEY:
        return [None] * len(queries)
    pool = ThreadPoolExecutor(max_workers=MAX_PARALLEL)
    try:
        futures = [pool.submit(search_dish_photo, q) for q in queries]
        wait(futures, timeout=BATCH_BUDGET_SECONDS)
        out: List[Optional[dict]] = []
        for f in futures:
            try:
                out.append(f.result(timeout=0) if f.done() else None)
            except Exception:  # noqa: BLE001
                out.append(None)
        return out
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
