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
    account. An explicit Restore (transfer=True) MOVES it to the newest account
    and revokes it from the old one (never grants both).
  * appAccountToken (set by the client at purchase to the user's account id):
      - On automatic sync (transfer=False) a PRESENT token MUST match the
        requesting user, and a subscription is never moved across accounts.
      - On an explicit Restore (transfer=True) the Apple-signed JWS — obtained via
        AppStore.sync(), which authenticates the Apple ID — proves the requester
        controls the owning Apple ID, so the subscription moves here even if the
        token belongs to another Platter account (newest-account-wins).
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
    user: User,
    signed_transaction: str,
    now: Optional[datetime] = None,
    transfer: bool = False,
) -> EntitlementStatus:
    """Verify a StoreKit 2 signed transaction against Apple and persist the
    resulting entitlement for `user`. Raises an `EntitlementError` subclass on any
    failure; grants nothing unless verification fully succeeds.

    `transfer` controls cross-account movement of a subscription:
      * transfer=False (automatic launch / sign-in / Transaction.updates sync):
        REFRESH ONLY — never move a subscription owned by another account. Grants
        only when the transaction's appAccountToken matches this account, or this
        account already owns the subscription. A tokenless transaction never
        auto-grants to a new account. This is what stops any account on a device
        whose Apple ID has a subscription from silently becoming Pro.
      * transfer=True (explicit "Restore Purchases" tap): newest-account-wins —
        move the subscription to this account and revoke it from the previous one,
        even if the transaction's appAccountToken belongs to another account. The
        Apple-signed JWS (from AppStore.sync(), which authenticates the Apple ID)
        proves the requester controls the owning Apple ID.
    A PRESENT appAccountToken must match the requester only on automatic sync
    (transfer=False)."""
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

    has_token = bool(verified.app_account_token)
    token_matches = has_token and _uuid_norm(verified.app_account_token) == _uuid_norm(user.id)

    existing = db.get_entitlement_by_original_txn(verified.original_transaction_id)
    owned_by_other = bool(existing) and existing["user_id"] != user.id

    if transfer:
        # Explicit Restore: newest account wins. The Apple-signed JWS proves the
        # requester controls the owning Apple ID, so move the subscription here even
        # when its appAccountToken belongs to another account, and revoke it from the
        # previous owner. (No appAccountToken gate on this path — that is what makes
        # "Restore to this account" work for a new account.)
        if owned_by_other:
            db.delete_entitlement(existing["user_id"])
    else:
        # Automatic sync: a PRESENT appAccountToken must match the requester, and a
        # subscription is never moved across accounts (refresh only).
        if has_token and not token_matches:
            raise AccountMismatchError("transaction belongs to a different account")
        if owned_by_other:
            # Owned by a different account: do not transfer. No-op for this account.
            return status_for_user(user.id, moment)
        already_mine = bool(existing) and existing["user_id"] == user.id
        if not (has_token or already_mine):
            # Tokenless and not already this account's subscription: never auto-grant.
            return status_for_user(user.id, moment)

    # Billing-grace expiry (best-effort; None when the API key isn't configured or
    # the subscription isn't in grace).
    grace_dt = appstore.fetch_grace_expiry(verified.original_transaction_id, verified.environment)

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


# --------------------------------------------------------------------------- #
# App Store Server Notifications V2 — apply a verified notification
# --------------------------------------------------------------------------- #

# Notification types that renew/extend the active period (clear any billing grace).
_RENEWED_TYPES = frozenset({"DID_RENEW", "SUBSCRIBED", "OFFER_REDEEMED", "RESUBSCRIBE"})


def apply_notification(parsed, now: Optional[datetime] = None) -> str:
    """Apply a verified App Store notification to the stored entitlement.

    IDEMPOTENT: the new expiry/grace are recomputed from the notification's own
    authoritative timestamps, so Apple's retries (or out-of-order redeliveries)
    converge to the same row. Only updates an EXISTING entitlement, keyed by
    `original_transaction_id` — a notification for a subscription we've never
    verified from a client is logged and ignored (we can't attribute it to an
    account). Returns a short action label for logging. Never raises on a normal
    outcome."""
    moment = _now(now)
    otid = parsed.original_transaction_id
    if not otid:
        return "ignored_no_transaction"
    existing = db.get_entitlement_by_original_txn(otid)
    if not existing:
        return "ignored_unknown_subscription"

    nt = parsed.notification_type
    pro_dt = _parse(existing.get("pro_expires_at"))
    grace_dt = _parse(existing.get("grace_expires_at"))
    product = parsed.product_id or existing.get("product_id")

    if nt in _RENEWED_TYPES:
        # Renewed: extend the active period, no longer in grace.
        pro_dt = parsed.expires_at or pro_dt
        grace_dt = None
    elif nt == "DID_FAIL_TO_RENEW":
        # Billing issue. If Apple opened a billing-grace window, the renewal info
        # carries its expiry; otherwise there is no grace (plain billing retry).
        grace_dt = parsed.grace_expires_at
    elif nt == "GRACE_PERIOD_EXPIRED":
        # Grace ended without recovery — drop grace (access ends unless still paid).
        grace_dt = None
    elif nt == "EXPIRED":
        # Subscription lapsed; reflect the transaction's own (past) expiry, no grace.
        pro_dt = parsed.expires_at or pro_dt
        grace_dt = None
    elif nt in ("REFUND", "REVOKE"):
        # Refunded or access revoked (e.g. Family Sharing) — end access now.
        pro_dt = None
        grace_dt = None
    elif nt == "DID_CHANGE_RENEWAL_STATUS":
        # Auto-renew toggled on/off — current access is unchanged; just refresh the
        # expiry if the transaction carried one.
        if parsed.expires_at:
            pro_dt = parsed.expires_at
    else:
        # Types we don't act on (PRICE_INCREASE, CONSUMPTION_REQUEST, TEST, …).
        return f"ignored_type:{nt}"

    # A revoked transaction always ends access, whatever the type says.
    if parsed.revocation_date:
        pro_dt = None
        grace_dt = None

    db.upsert_entitlement(
        user_id=existing["user_id"],
        product_id=product,
        original_transaction_id=otid,
        pro_expires_at=_iso(pro_dt),
        grace_expires_at=_iso(grace_dt),
        environment=parsed.environment or existing.get("environment") or "Production",
        last_verified_at=existing.get("last_verified_at") or _iso(moment),
        updated_at=_iso(moment),
    )
    return f"applied:{nt}"
