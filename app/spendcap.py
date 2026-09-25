"""Hard per-account spend cap — an ENFORCING dollar backstop above the
count-based burst caps (app/burstlimit.py) and the advisory spend flag
(app/spendsignal.py).

Where the burst caps bound the NUMBER of LLM calls per account per day and the
spend signal only FLAGS high spenders for manual review, this module actually
BLOCKS: once an account's estimated LLM spend over the TRAILING 30 DAYS (summed
from the llm_cost_events ledger) is at/over `PER_ACCOUNT_30D_SPEND_CAP_USD`, the
LLM-backed endpoints reject further calls with HTTP 429.

Design notes:
  * PER ACCOUNT, keyed on the verified account id (never a spoofable header), so
    it applies to Pro and free alike — cost is cost. Only reachable on the
    authenticated LLM endpoints, so there is always an account to key on.
  * ROLLING 30-day window (not a fixed calendar reset): the cap eases as old
    spend ages past the cutoff, so a blocked account recovers gradually rather
    than all at once at a reset instant. Mirrors the advisory spend signal's
    trailing-window shape (app/spendsignal.py).
  * PRE-check against ALREADY-recorded spend: cost is written after each call
    (app/llm_cost.track), so this reflects prior calls in the window. A single
    call can overshoot the cap by at most one call's cost — fine for a backstop.
  * Disabled when `PER_ACCOUNT_30D_SPEND_CAP_USD <= 0`, so deployments can fall
    back to the count caps + advisory flag only.

Kept side-effect-light and unit-testable like burstlimit / spendsignal.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional

from . import config, db

_WINDOW_DAYS = 30


class SpendCapExceeded(Exception):
    """Raised by `check` when an account is at/over its hard 30-day spend cap.

    `code` is the stable machine string the API surfaces (HTTP 429). It is
    distinct from the count-based burst caps' `rate_limit_exceeded` so logs (and
    the client) can tell a dollar-cap trip from a call-count trip."""

    code = "spend_cap_reached"

    def __init__(self, limit_usd: float, spent_usd: float):
        self.limit = limit_usd
        self.spent = spent_usd
        self.window_label = "30d"  # rolling window; NOT a calendar month
        super().__init__(
            f"30-day spend cap exceeded (${spent_usd:.4f} of ${limit_usd:.2f} in the trailing {_WINDOW_DAYS}d)"
        )


def check(account_id: str, now: Optional[datetime] = None) -> None:
    """Raise SpendCapExceeded if this account has already spent at/over the cap in
    the trailing 30 days. No-op when the cap is disabled (<= 0). Called BEFORE any
    LLM work on the authenticated LLM endpoints."""
    cap = config.PER_ACCOUNT_30D_SPEND_CAP_USD
    if cap <= 0:
        return
    now = now or datetime.now(timezone.utc)
    cutoff = (now - timedelta(days=_WINDOW_DAYS)).astimezone(timezone.utc).isoformat()
    spent = db.account_spend_since(account_id, cutoff)
    if spent >= cap:
        raise SpendCapExceeded(cap, spent)
