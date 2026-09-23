"""Device-level account-creation abuse signal (advisory, never a hard block).

When a new account is created we record which device (the client's persistent
`X-User-Id`) it came from. If that device already created ANOTHER account within
the trailing `DEVICE_MULTI_ACCOUNT_WINDOW_DAYS`, the new account is FLAGGED for
manual review — we do NOT block it. Shared devices and app reinstalls make false
positives expected, so this is a triage signal (queryable via
`db.list_flagged_accounts` / `db.get_account_device_signal`), not an automatic
restriction.

Kept as its own module (like importlimit / burstlimit) so the policy is
side-effect-light and unit-testable without standing up the auth router.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from . import config, db

_log = logging.getLogger("uvicorn.error")


def record_new_account(account_id: str, device_id: Optional[str], created_at_iso: str) -> bool:
    """Record the device a newly-created account came from, flagging it if that
    device created another account within the trailing window. Returns whether the
    account was flagged.

    NEVER raises: a signal failure must not block sign-up, and an absent/blank
    device id is recorded unflagged (a null device never correlates with another).
    """
    try:
        device_id = (device_id or "").strip() or None
        flagged = False
        related: Optional[str] = None
        if device_id:
            cutoff = (
                datetime.now(timezone.utc)
                - timedelta(days=config.DEVICE_MULTI_ACCOUNT_WINDOW_DAYS)
            ).isoformat()
            prior = db.recent_accounts_for_device(device_id, cutoff, exclude_account_id=account_id)
            if prior:
                flagged = True
                related = prior[0]  # most recent prior account on this device
                _log.warning(
                    "device-signal: account %s created on device %s within %sd of "
                    "prior account %s — FLAGGED for manual review",
                    account_id,
                    device_id,
                    config.DEVICE_MULTI_ACCOUNT_WINDOW_DAYS,
                    related,
                )
        db.record_account_device_signal(account_id, device_id, created_at_iso, flagged, related)
        return flagged
    except Exception:  # noqa: BLE001 - advisory signal must never break signup
        _log.exception("device-signal recording failed for account %s", account_id)
        return False
