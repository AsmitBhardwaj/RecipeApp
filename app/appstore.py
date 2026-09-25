"""Apple App Store verification wrapper (server-verified Pro entitlement).

Thin seam over Apple's official `app-store-server-library`, isolated here so the
policy layer (app/entitlements.py) and the tests never touch Apple's SDK types
directly and can inject fakes.

Two distinct Apple capabilities are used:

  * OFFLINE signature verification of a StoreKit 2 signed transaction (JWS): the
    library checks the certificate chain to the Apple root certs bundled in
    app/appstore_certs/, plus the bundle id and (for production) the numeric app
    id. This needs NO secret — just the public root certs. `verify_transaction`.

  * The App Store Server API, to read a subscription's STATUS (its signed
    renewal info), which carries `gracePeriodExpiresDate` — the billing-grace
    expiry a bare transaction does not include. This needs the API key
    (issuer id / key id / .p8). `fetch_grace_expiry`. Best-effort: if the key is
    unset or the call fails, grace is simply unknown (None) and the entitlement
    still reflects the transaction's own expiry.

Environment handling follows Apple's guidance: verify against PRODUCTION first,
then fall back to SANDBOX, because App Review and TestFlight send Sandbox
transactions to the production server. The environment Apple actually reports is
returned and stored per entitlement — we never rely on a single configured env.
"""
from __future__ import annotations

import glob
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import List, Optional

from . import config

_log = logging.getLogger("uvicorn.error")

_CERTS_DIR = os.path.join(os.path.dirname(__file__), "appstore_certs")

# Online (OCSP) revocation checks add a network round-trip to every verify; the
# offline chain-to-root check is what stops forged transactions. Left off by
# default for determinism and latency; flip via APPSTORE_ONLINE_CHECKS=1.
_ENABLE_ONLINE_CHECKS = (os.getenv("APPSTORE_ONLINE_CHECKS") or "").strip() in ("1", "true", "yes")


class AppStoreNotConfigured(Exception):
    """Verification was attempted but the Apple root certs could not be loaded."""


class InvalidTransaction(Exception):
    """A signed transaction failed verification (bad signature/chain, wrong
    bundle id, or unverifiable in both Production and Sandbox)."""


class InvalidNotification(Exception):
    """An App Store Server Notification (V2) failed signature verification."""


@dataclass(frozen=True)
class VerifiedTransaction:
    """The subset of a verified StoreKit transaction the entitlement layer needs."""

    product_id: str
    original_transaction_id: str
    bundle_id: str
    environment: str  # "Production" / "Sandbox" — what Apple reported
    expires_at: Optional[datetime]
    app_account_token: Optional[str]
    revocation_date: Optional[datetime]


@dataclass(frozen=True)
class ParsedNotification:
    """The verified, decoded contents of an App Store Server Notification (V2) that
    the entitlement layer needs to update a stored row."""

    notification_type: Optional[str]
    subtype: Optional[str]
    notification_uuid: Optional[str]
    environment: Optional[str]
    original_transaction_id: Optional[str]
    product_id: Optional[str]
    expires_at: Optional[datetime]
    revocation_date: Optional[datetime]
    grace_expires_at: Optional[datetime]


def _ms_to_dt(ms: Optional[int]) -> Optional[datetime]:
    if ms is None:
        return None
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc)


def _load_root_certs() -> List[bytes]:
    certs = [open(p, "rb").read() for p in sorted(glob.glob(os.path.join(_CERTS_DIR, "*.cer")))]
    if not certs:
        raise AppStoreNotConfigured("no Apple root certificates found in appstore_certs/")
    return certs


# Cache verifiers/clients per environment so repeated verifies don't re-parse
# certs or re-init the SDK. Keyed by the Apple Environment enum.
_verifier_cache: dict = {}


def _verifier_for(environment):
    """Build (and cache) a SignedDataVerifier for one Apple environment. Raises if
    the environment needs config we don't have (production needs the app apple id)."""
    from appstoreserverlibrary.models.Environment import Environment

    if environment in _verifier_cache:
        return _verifier_cache[environment]

    from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier

    app_apple_id = config.APPSTORE_APP_APPLE_ID if environment == Environment.PRODUCTION else None
    if environment == Environment.PRODUCTION and app_apple_id is None:
        # The library refuses to build a production verifier without the app id.
        raise AppStoreNotConfigured("APPSTORE_APP_APPLE_ID required to verify production transactions")

    verifier = SignedDataVerifier(
        _load_root_certs(),
        _ENABLE_ONLINE_CHECKS,
        environment,
        config.APPSTORE_BUNDLE_ID,
        app_apple_id,
    )
    _verifier_cache[environment] = verifier
    return verifier


def _ordered_environments():
    """Production first, then Sandbox — Apple's recommended try order."""
    from appstoreserverlibrary.models.Environment import Environment

    return [Environment.PRODUCTION, Environment.SANDBOX]


def verify_transaction(signed_transaction: str) -> VerifiedTransaction:
    """Verify a StoreKit 2 signed transaction (JWS) against Apple.

    Tries Production, then Sandbox. Returns the decoded, verified transaction, or
    raises `InvalidTransaction` if neither environment accepts it (bad
    signature/chain or wrong bundle id). Never trusts unverified input."""
    from appstoreserverlibrary.signed_data_verifier import VerificationException

    last_error: Optional[Exception] = None
    for environment in _ordered_environments():
        try:
            verifier = _verifier_for(environment)
        except AppStoreNotConfigured as exc:
            # e.g. production verifier unavailable (no app id) — try the next env.
            last_error = exc
            continue
        try:
            payload = verifier.verify_and_decode_signed_transaction(signed_transaction)
        except VerificationException as exc:
            # Wrong environment (a Sandbox tx checked against Production) or an
            # actual failure — either way, try the next environment.
            last_error = exc
            continue

        env_value = payload.environment.value if payload.environment is not None else environment.value
        return VerifiedTransaction(
            product_id=payload.productId,
            original_transaction_id=payload.originalTransactionId,
            bundle_id=payload.bundleId,
            environment=env_value,
            expires_at=_ms_to_dt(payload.expiresDate),
            app_account_token=payload.appAccountToken,
            revocation_date=_ms_to_dt(payload.revocationDate),
        )

    raise InvalidTransaction(f"transaction failed verification: {last_error}")


def _enum_value(obj, raw):
    """An app-store-server-library enum field is None for values the SDK doesn't
    recognize; fall back to the paired `raw*` string so new Apple types still flow
    through as data."""
    return obj.value if obj is not None else raw


def parse_notification(signed_payload: str) -> ParsedNotification:
    """Verify an App Store Server Notification (V2) against Apple and decode the
    parts needed to update an entitlement. Tries Production then Sandbox. The
    embedded transaction/renewal info is verified with the SAME environment
    verifier that accepted the notification. Raises `InvalidNotification` if
    neither environment accepts the signature."""
    from appstoreserverlibrary.signed_data_verifier import VerificationException

    last_error: Optional[Exception] = None
    for environment in _ordered_environments():
        try:
            verifier = _verifier_for(environment)
        except AppStoreNotConfigured as exc:
            last_error = exc
            continue
        try:
            payload = verifier.verify_and_decode_notification(signed_payload)
        except VerificationException as exc:
            last_error = exc
            continue

        data = payload.data
        env_value = environment.value
        original_txn: Optional[str] = None
        product_id: Optional[str] = None
        expires_at: Optional[datetime] = None
        revocation_date: Optional[datetime] = None
        grace_expires_at: Optional[datetime] = None

        if data is not None:
            if data.environment is not None:
                env_value = data.environment.value
            if data.signedTransactionInfo:
                txn = verifier.verify_and_decode_signed_transaction(data.signedTransactionInfo)
                original_txn = txn.originalTransactionId
                product_id = txn.productId
                expires_at = _ms_to_dt(txn.expiresDate)
                revocation_date = _ms_to_dt(txn.revocationDate)
            if data.signedRenewalInfo:
                renewal = verifier.verify_and_decode_renewal_info(data.signedRenewalInfo)
                grace_expires_at = _ms_to_dt(renewal.gracePeriodExpiresDate)
                if original_txn is None:
                    original_txn = renewal.originalTransactionId

        return ParsedNotification(
            notification_type=_enum_value(payload.notificationType, payload.rawNotificationType),
            subtype=_enum_value(payload.subtype, payload.rawSubtype),
            notification_uuid=payload.notificationUUID,
            environment=env_value,
            original_transaction_id=original_txn,
            product_id=product_id,
            expires_at=expires_at,
            revocation_date=revocation_date,
            grace_expires_at=grace_expires_at,
        )

    raise InvalidNotification(f"notification failed verification: {last_error}")


def _api_configured() -> bool:
    return bool(
        config.APPSTORE_ISSUER_ID and config.APPSTORE_KEY_ID and config.APPSTORE_PRIVATE_KEY
    )


def fetch_grace_expiry(original_transaction_id: str, environment: str) -> Optional[datetime]:
    """Look up a subscription's billing-grace expiry via the App Store Server API.

    Returns the `gracePeriodExpiresDate` when the subscription is in (or entered)
    billing grace, else None. Best-effort: any misconfiguration or API/verify
    error returns None (grace unknown) rather than failing the whole verify — the
    entitlement still reflects the transaction's own expiry, and a later App Store
    Server Notification can fill grace in."""
    if not _api_configured():
        return None
    try:
        from appstoreserverlibrary.api_client import AppStoreServerAPIClient
        from appstoreserverlibrary.models.Environment import Environment

        env = Environment(environment)
        client = AppStoreServerAPIClient(
            config.APPSTORE_PRIVATE_KEY.encode("utf-8"),
            config.APPSTORE_KEY_ID,
            config.APPSTORE_ISSUER_ID,
            config.APPSTORE_BUNDLE_ID,
            env,
        )
        response = client.get_all_subscription_statuses(original_transaction_id)
        verifier = _verifier_for(env)
        for group in response.data or []:
            for txn in group.lastTransactions or []:
                if txn.originalTransactionId != original_transaction_id:
                    continue
                if not txn.signedRenewalInfo:
                    continue
                renewal = verifier.verify_and_decode_renewal_info(txn.signedRenewalInfo)
                return _ms_to_dt(renewal.gracePeriodExpiresDate)
    except Exception as exc:  # noqa: BLE001 — grace is best-effort, never fatal
        _log.warning("grace-period lookup failed for %s: %s", original_transaction_id, exc)
    return None
