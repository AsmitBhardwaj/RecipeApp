"""Soft spend-based circuit breaker (advisory, never a hard block).

A backstop on top of the per-call rate/burst caps. If an account's trailing
`SPEND_FLAG_WINDOW_DAYS` estimated LLM spend (summed from the llm_cost_events
ledger — app/llm_cost.py) exceeds `SPEND_FLAG_THRESHOLD_USD`, the account is
FLAGGED for manual review. We do NOT block it — a real power user must never be
silently cut off — exactly like the device-multi-account signal
(app/devicesignal.py). This is visibility only, surfaced in the admin panel
(`/admin/flagged-accounts`).

Unlike the device signal (a point-in-time creation event that must be persisted
because it can't be recomputed later), spend is always derivable from the ledger,
so the flag is computed ON DEMAND at review time. That keeps it always-current
and adds ZERO overhead to the request/extraction path.

Kept as its own module (like devicesignal / burstlimit) so the policy is
side-effect-light and unit-testable without standing up the admin router.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from . import config, db

_log = logging.getLogger("uvicorn.error")


def flagged_accounts(now: Optional[datetime] = None) -> list[dict]:
    """Accounts whose trailing-window estimated spend is over the threshold,
    highest first. Each row: {account_id, estimated_cost_usd, calls}. Advisory
    only. NEVER raises — a signal failure must not take down the admin view; on
    error it returns an empty list and logs."""
    try:
        now = now or datetime.now(timezone.utc)
        cutoff = (now - timedelta(days=config.SPEND_FLAG_WINDOW_DAYS)).isoformat()
        rows = db.accounts_over_spend(cutoff, config.SPEND_FLAG_THRESHOLD_USD)
        if rows:
            _log.warning(
                "spend-signal: %d account(s) over $%.2f in the trailing %dd — "
                "FLAGGED for manual review (advisory, not blocked)",
                len(rows),
                config.SPEND_FLAG_THRESHOLD_USD,
                config.SPEND_FLAG_WINDOW_DAYS,
            )
        return rows
    except Exception:  # noqa: BLE001 - advisory signal must never break the admin view
        _log.exception("spend-signal evaluation failed")
        return []
