"""Persistent, multi-dimension fixed-window rate limiting (CLAUDE.md §7).

Replaces the old in-memory limiter: counters live in SQLite (reusing the WAL
setup in app/db.py) so limits survive restarts/redeploys and are shared across
workers/processes instead of resetting on every deploy.

Two identity dimensions are checked, each over a per-minute and a per-hour
window:

  * per user-id  — from the client-supplied `X-User-Id` header. This is a
                   spoofable, unverified UUID: treat it as an abuse-deterrence
                   signal, NOT identity/auth.
  * per IP       — the real client IP (first `X-Forwarded-For` hop behind the
                   Railway proxy). This is what bounds an attacker who simply
                   rotates the X-User-Id header — defense in depth.

Fixed-window counters (not a sliding log) keep the storage to one row per
(identity, window) and the check to a single UPSERT.
"""
from __future__ import annotations

import random
import time
from dataclasses import dataclass

from . import config, db

_MINUTE = 60
_HOUR = 3600
# Largest window we keep; rows older than this can never be read again.
_MAX_WINDOW = _HOUR
# Chance a given check also runs a global cleanup sweep. A beta has few distinct
# identities, so the table stays tiny without needing a scheduler/cron.
_CLEANUP_PROBABILITY = 0.01


@dataclass(frozen=True)
class _Rule:
    dimension: str  # "u" (user-id) or "ip"
    window: int     # window length in seconds
    limit: int      # max requests allowed within the window


def _rules() -> list[_Rule]:
    # Read config fresh each call so tests can monkeypatch the limits.
    return [
        _Rule("u", _MINUTE, config.RATE_LIMIT_USER_PER_MIN),
        _Rule("u", _HOUR, config.RATE_LIMIT_USER_PER_HOUR),
        _Rule("ip", _MINUTE, config.RATE_LIMIT_IP_PER_MIN),
        _Rule("ip", _HOUR, config.RATE_LIMIT_IP_PER_HOUR),
    ]


class RateLimitExceeded(Exception):
    """Raised by `check` when any dimension is over its limit."""

    def __init__(self, dimension: str, window: int, limit: int):
        self.dimension = dimension
        self.window = window
        self.limit = limit
        unit = "min" if window == _MINUTE else "hour"
        label = "user" if dimension == "u" else "ip"
        super().__init__(f"rate limit exceeded ({limit}/{unit} per {label})")


def check(user_id: str, ip: str) -> None:
    """Count this request against every bucket and raise RateLimitExceeded on the
    first dimension that is over its limit.

    We increment *then* compare, so the request that trips a limit still counts
    against its window — a client hammering the endpoint stays blocked rather
    than getting a free request each window edge. The per-minute rules are
    listed first so the tighter window is what a burst hits.
    """
    now = int(time.time())
    identities = {"u": user_id, "ip": ip}
    for rule in _rules():
        ident = identities[rule.dimension]
        window_start = now - (now % rule.window)
        bucket_key = f"{rule.dimension}:{ident}:{rule.window}"
        count = db.rate_limit_incr(bucket_key, window_start)
        if count > rule.limit:
            raise RateLimitExceeded(rule.dimension, rule.window, rule.limit)
    _maybe_cleanup(now)


def _maybe_cleanup(now: int) -> None:
    if random.random() < _CLEANUP_PROBABILITY:
        db.rate_limit_cleanup(now - _MAX_WINDOW)
