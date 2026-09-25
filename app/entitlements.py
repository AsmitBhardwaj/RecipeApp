"""Server-verified Pro entitlement — the single source of truth for Pro access.

Replaces the old spoofable `X-Pro-Entitled` header. Pro is granted ONLY by a
StoreKit 2 transaction the client posts to `/v1/entitlements/verify`, verified
against Apple (app/appstore.py) and persisted per account (the `entitlements`
table). Every server-side gate now reads `is_pro_user(...)`.

Policy (matches the 16-day Billing Grace Period enabled in App Store Connect):

    Pro  ==  pro_expires_at   > now   (subscription active)
         OR  grace_expires_at > now   (in billing grace — still Pro until grace
                                        actually lapses)

Account binding:
  * One Apple subscription (`original_transaction_id`) maps to at most one Platter
    account. Verifying it from a different account MOVES it to the newest account
    and revokes it from the old one (never grants both).
  * When the transaction carries an `appAccountToken` (set by the client at
    purchase to the user's account id), it MUST match the requesting user.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from . import appstore, config, db
from .auth.service import User


class EntitlementError(Exception):
    """Base for verify failures. `code` is the stable machine string the API
    surfaces; `status` is the HTTP status the router maps it to."""

    code = "entitlement_error"
    status = 400


class InvalidTransactionError(EntitlementError):
    code = "invalid_transaction"
    status = 400


class UnknownProductError(EntitlementError):
    code = "unknown_product"
    status = 400


class AccountMismatchError(EntitlementError):
    code = "account_mismatch"
    status = 403


class NotConfiguredError(EntitlementError):
    code = "verification_unavailable"
    status = 503


@dataclass(frozen=True)
class EntitlementStatus:
    is_pro: bool
    product_id: Optional[str]
    pro_expires_at: Optional[str]
    grace_expires_at: Optional[str]
    environment: Optional[str]


def _now(now: Optional[datetime]) -> datetime:
    return now or datetime.now(timezone.utc)


def _parse(iso: Optional[str]) -> Optional[datetime]:
    if not iso:
        return None
    try:
        dt = datetime.fromisoformat(iso)
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _iso(dt: Optional[datetime]) -> Optional[str]:
    return dt.astimezone(timezone.utc).isoformat() if dt else None


def _uuid_norm(value: str) -> str:
    """Compare account ids/appAccountTokens irrespective of hyphenation/case.
    Falls back to a stripped/lowercased string when a value isn't a UUID."""
    try:
        return uuid.UUID(value).hex
    except (ValueError, AttributeError, TypeError):
        return (value or "").replace("-", "").lower()


# --------------------------------------------------------------------------- #
# Read side — the single Pro check every gate uses
# --------------------------------------------------------------------------- #


def is_pro_record(record: Optional[dict], now: Optional[datetime] = None) -> bool:
    """True when a stored entitlement grants Pro right now: active OR in billing
    grace. A missing row is not Pro."""
    if not record:
        return False
    moment = _now(now)
    pro = _parse(record.get("pro_expires_at"))
    grace = _parse(record.get("grace_expires_at"))
    return bool((pro and pro > moment) or (grace and grace > moment))


def is_pro_user(user_id: Optional[str], now: Optional[datetime] = None) -> bool:
    """Server-authoritative Pro check for an account id. Anonymous (None) is never
    Pro."""
    if not user_id:
        return False
    return is_pro_record(db.get_entitlement(user_id), now)


def status_for_user(user_id: str, now: Optional[datetime] = None) -> EntitlementStatus:
    record = db.get_entitlement(user_id)
    return EntitlementStatus(
        is_pro=is_pro_record(record, now),
        product_id=record.get("product_id") if record else None,
        pro_expires_at=record.get("pro_expires_at") if record else None,
        grace_expires_at=record.get("grace_expires_at") if record else None,
        environment=record.get("environment") if record else None,
    )


# --------------------------------------------------------------------------- #
# Write side — verify a signed transaction and persist entitlement
# --------------------------------------------------------------------------- #


def verify_and_store(
    user: User, signed_transaction: str, now: Optional[datetime] = None
) -> EntitlementStatus:
    """Verify a StoreKit 2 signed transaction against Apple and persist the
    resulting entitlement for `user`. Raises an `EntitlementError` subclass on any
    failure; grants nothing unless verification fully succeeds."""
    moment = _now(now)

    try:
        verified = appstore.verify_transaction(signed_transaction)
    except appstore.AppStoreNotConfigured as exc:
        raise NotConfiguredError(str(exc)) from exc
    except appstore.InvalidTransaction as exc:
        raise InvalidTransactionError(str(exc)) from exc

    # Defense in depth: the verifier already checks the bundle id, but never trust
    # a mismatch through.
    if verified.bundle_id != config.APPSTORE_BUNDLE_ID:
        raise InvalidTransactionError("bundle id mismatch")

    if verified.product_id not in config.APPSTORE_PRODUCT_IDS:
        raise UnknownProductError(f"unrecognized product id: {verified.product_id}")

    # A present appAccountToken must belong to the requesting account.
    if verified.app_account_token and _uuid_norm(verified.app_account_token) != _uuid_norm(user.id):
        raise AccountMismatchError("transaction belongs to a different account")

    # Billing-grace expiry (best-effort; None when the API key isn't configured or
    # the subscription isn't in grace).
    grace_dt = appstore.fetch_grace_expiry(verified.original_transaction_id, verified.environment)

    # Binding: one subscription -> at most one account. If another account already
    # owns this subscription, revoke it there (newest verifier wins).
    existing = db.get_entitlement_by_original_txn(verified.original_transaction_id)
    if existing and existing["user_id"] != user.id:
        db.delete_entitlement(existing["user_id"])

    # A revoked (refunded) transaction expires access immediately.
    pro_dt = None if verified.revocation_date else verified.expires_at

    db.upsert_entitlement(
        user_id=user.id,
        product_id=verified.product_id,
        original_transaction_id=verified.original_transaction_id,
        pro_expires_at=_iso(pro_dt),
        grace_expires_at=_iso(grace_dt),
        environment=verified.environment,
        last_verified_at=_iso(moment),
        updated_at=_iso(moment),
    )
    return status_for_user(user.id, moment)
