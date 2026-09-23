"""Per-account burst/daily caps on the LLM-backed endpoints — a hard cost ceiling
that applies even where the free-tier monthly cap does not (CLAUDE.md §7).

Layered ON TOP of two existing controls:
  * the generic per-user-id / per-IP limiter (app/ratelimit.py), and
  * the free-tier monthly import cap (app/importlimit.py).

Unlike the monthly cap, these apply to PRO accounts too: Pro removes the monthly
cap, not the burst ceiling. Over-limit raises `BurstLimitExceeded`, whose `code`
("rate_limit_exceeded") is deliberately distinct from the import cap's
`free_limit_reached` — a Pro user who trips a burst limit must see a "slow down"
message, never the paywall.

Mechanism: the same persistent fixed-window counter the rest of the app uses
(`db.rate_limit_incr`), so counts survive restarts/redeploys and are shared
across workers instead of living in per-process memory. Windows are UTC-aligned
(`now - now % window`), so the daily bucket resets at UTC midnight and the hourly
bucket on the hour.

Each endpoint family has its own bucket namespace (`burst:<scope>:<account>:<window>`)
so its limit is counted independently — an import never eats a budget-plan's
allowance, and vice versa.
"""
from __future__ import annotations

import time
from typing import List, Tuple

from . import config, db

_HOUR = 3600
_DAY = 86400


class BurstLimitExceeded(Exception):
    """Raised by the `check_*` helpers when an account is over one of its caps.

    `code` is the stable machine string the API surfaces (HTTP 429) so the client
    can tell this apart from the free-import paywall (`free_limit_reached`, 402).
    """

    code = "rate_limit_exceeded"

    def __init__(self, scope: str, window: int, limit: int):
        self.scope = scope
        self.window = window
        self.limit = limit
        self.window_label = "hour" if window == _HOUR else "day"
        super().__init__(f"{scope} rate limit exceeded ({limit}/{self.window_label})")


def _check(scope: str, account_id: str, rules: List[Tuple[int, int]]) -> None:
    """Count this request against every bucket in `rules` and raise on the first
    that is over its limit.

    `rules` is (window_seconds, limit) pairs, TIGHTEST WINDOW FIRST, so a burst
    trips the short window before the long one. We increment then compare (like
    ratelimit.check), so the request that trips a limit still counts against its
    window — a client hammering the endpoint stays blocked rather than getting a
    free hit at each window edge.
    """
    now = int(time.time())
    for window, limit in rules:
        window_start = now - (now % window)
        bucket_key = f"burst:{scope}:{account_id}:{window}"
        count = db.rate_limit_incr(bucket_key, window_start)
        if count > limit:
            raise BurstLimitExceeded(scope, window, limit)


def check_import(account_id: str) -> None:
    """Import burst cap: per-hour first (so a burst trips it before the daily)."""
    _check(
        "import",
        account_id,
        [(_HOUR, config.BURST_IMPORT_PER_HOUR), (_DAY, config.BURST_IMPORT_PER_DAY)],
    )


def check_budget_plan(account_id: str) -> None:
    """Budget-plan generation: per-day cap, independent of the import caps."""
    _check("budget", account_id, [(_DAY, config.BURST_BUDGET_PLAN_PER_DAY)])


def check_pantry(account_id: str) -> None:
    """Pantry suggestions: per-day cap, independent of the import/budget caps."""
    _check("pantry", account_id, [(_DAY, config.BURST_PANTRY_PER_DAY)])
