"""Free-tier monthly import limit — the server side of Platter Pro's "Unlimited
imports" (CLAUDE.md §2).

Kept as its own small, side-effect-light module (like app/ratelimit.py) so the
policy — who is limited, when, and how a month is bucketed — is independently
unit-testable without standing up the FastAPI app. The endpoints in app/main.py
call `check_allowed(...)` BEFORE doing any extraction work, and the orchestrator
calls `record_success(...)` from its single `_finalize` chokepoint.

Design (see config.FREE_IMPORT_LIMIT / FREE_LIMIT_EFFECTIVE_DATE):

  * Enforced PER ACCOUNT (verified JWT), so it holds across a user's devices and
    the Share Extension. Anonymous/unauthenticated imports (`account is None`)
    are NOT limited here — they are bounded only by the per-user/IP rate limiter
    (app/ratelimit.py). This is the deliberate "smallest safe version" trade-off:
    the app itself always runs signed-in, and we do not paywall a request we
    cannot attribute to an account.
  * Pro accounts are never limited. `is_pro` is the SERVER-VERIFIED entitlement
    (app/entitlements.py) — an Apple-verified StoreKit transaction persisted per
    account, honoring billing grace — passed in by the caller. It is no longer a
    client-trusted header.
  * GRANDFATHERING: accounts created strictly before FREE_LIMIT_EFFECTIVE_DATE
    are exempt forever, so moving the date forward never retroactively restricts an
    existing user. The default date is in the past (1970), so NO account is
    grandfathered and the five-import free plan applies to everyone — the intended
    launch behavior. Push the date into the future only to exempt existing users
    before a later launch.
  * Counting is by SUCCESSFUL import (a job that reaches `_finalize`), including
    cache hits. Failed / site_blocked jobs never finalize, and a paste-text retry
    reuses the same job_id, so the ledger's job_id PRIMARY KEY prevents any
    double count (app/db.record_import_event).
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional, Protocol

from . import config, db


class _Account(Protocol):
    """Structural view of the fields the policy needs from an auth User."""

    id: str
    created_at: Optional[str]


class ImportLimitExceeded(Exception):
    """Raised by `check_allowed` when a free account is at/over its monthly cap.

    `code` is the stable machine string the API surfaces to the client so it can
    show the paywall (never a generic failure)."""

    code = "free_limit_reached"

    def __init__(self, limit: int, count: int):
        self.limit = limit
        self.count = count
        super().__init__(f"free import limit reached ({count}/{limit} this month)")


def month_key(when: datetime) -> str:
    """UTC calendar-month bucket, "YYYY-MM". Naive datetimes are treated as UTC."""
    if when.tzinfo is not None:
        when = when.astimezone(timezone.utc)
    return when.strftime("%Y-%m")


def _month_key_from_iso(created_at_iso: str) -> str:
    return month_key(datetime.fromisoformat(created_at_iso))


def is_grandfathered(created_at_iso: Optional[str]) -> bool:
    """True when an account predates the effective date and is exempt forever.

    A None `created_at` (should not happen for a DB-loaded account) is treated as
    NOT grandfathered — we never grant exemption we cannot prove."""
    if not created_at_iso:
        return False
    try:
        created = datetime.fromisoformat(created_at_iso)
        effective = datetime.fromisoformat(config.FREE_LIMIT_EFFECTIVE_DATE)
    except ValueError:
        # A malformed effective date must not silently disable the limit; a
        # malformed account timestamp must not silently grant exemption.
        return False
    return created < effective


def check_allowed(account: Optional[_Account], is_pro: bool, now: Optional[datetime] = None) -> None:
    """Raise ImportLimitExceeded if this import would exceed the free monthly cap.

    No-op (allowed) when: there is no identified account, the account is Pro, or
    the account is grandfathered. Otherwise counts this account's successful
    imports in the current UTC month and blocks once the count is at the limit.
    """
    if account is None or is_pro:
        return
    if is_grandfathered(account.created_at):
        return
    when = now or datetime.now(timezone.utc)
    count = db.count_imports_in_month(account.id, month_key(when))
    if count >= config.FREE_IMPORT_LIMIT:
        raise ImportLimitExceeded(config.FREE_IMPORT_LIMIT, count)


def record_success(account_id: Optional[str], job_id: str, created_at_iso: str) -> None:
    """Record one successful import against `account_id`'s monthly count. Skipped
    for anonymous imports (no account). Idempotent per job_id."""
    if not account_id:
        return
    db.record_import_event(account_id, job_id, _month_key_from_iso(created_at_iso), created_at_iso)
