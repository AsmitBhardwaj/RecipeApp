"""Entitlement endpoints: client transaction verification + App Store notifications.

  POST /v1/entitlements/verify      (authenticated) — the client posts a StoreKit
      2 signed transaction (JWS) after purchase / restore / Transaction.updates /
      launch. We verify it against Apple and persist Pro for the account.

  POST /v1/appstore/notifications   (public, Apple-signed) — App Store Server
      Notifications V2. STUB: verifies the signed payload and updates the stored
      entitlement by original_transaction_id for renew/expire/refund/grace events.
      See the module notes for what remains to finish it.
"""
from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from . import appstore, config, db, entitlements
from .auth.router import current_user
from .auth.service import User
from .entitlements import EntitlementError

_log = logging.getLogger("uvicorn.error")

router = APIRouter(prefix="/v1", tags=["entitlements"])


class VerifyRequest(BaseModel):
    # StoreKit 2 `Transaction.jwsRepresentation`.
    signed_transaction: str


class EntitlementStatusResponse(BaseModel):
    is_pro: bool
    product_id: Optional[str] = None
    pro_expires_at: Optional[str] = None
    grace_expires_at: Optional[str] = None
    environment: Optional[str] = None


@router.post("/entitlements/verify", response_model=EntitlementStatusResponse)
def verify_entitlement(
    req: VerifyRequest, user: User = Depends(current_user)
) -> EntitlementStatusResponse:
    try:
        status = entitlements.verify_and_store(user, req.signed_transaction)
    except EntitlementError as exc:
        raise HTTPException(
            status_code=exc.status,
            detail={"error_code": exc.code, "message": str(exc)},
        )
    return EntitlementStatusResponse(
        is_pro=status.is_pro,
        product_id=status.product_id,
        pro_expires_at=status.pro_expires_at,
        grace_expires_at=status.grace_expires_at,
        environment=status.environment,
    )


@router.get("/entitlements/me", response_model=EntitlementStatusResponse)
def my_entitlement(user: User = Depends(current_user)) -> EntitlementStatusResponse:
    """The account's current server-side entitlement (does not call Apple)."""
    status = entitlements.status_for_user(user.id)
    return EntitlementStatusResponse(
        is_pro=status.is_pro,
        product_id=status.product_id,
        pro_expires_at=status.pro_expires_at,
        grace_expires_at=status.grace_expires_at,
        environment=status.environment,
    )


# --------------------------------------------------------------------------- #
# App Store Server Notifications V2 — STUB
# --------------------------------------------------------------------------- #
#
# WHAT IT DOES NOW: verifies the Apple-signed payload, decodes the embedded
# transaction/renewal info, and (when we already track that subscription) updates
# the stored entitlement's expiry/grace so renewals, expiries, refunds and grace
# transitions are reflected without waiting for the client to re-verify.
#
# TO FINISH (follow-up):
#   1. Enter this URL in App Store Connect → your app → App Information →
#      "App Store Server Notifications", for BOTH Production and Sandbox:
#         https://recipeapp-production-3a60.up.railway.app/v1/appstore/notifications
#   2. Requires the same APPSTORE_* config as verify (root certs are bundled; the
#      API key is only needed for the grace lookup).
#   3. Decide/confirm per-type handling below and add tests with Apple's sample
#      signed payloads (or a fake verifier), mirroring test_entitlements.py.
#   4. Consider idempotency/ordering (notificationUUID) and Apple's retry policy
#      (return 2xx once accepted so Apple stops retrying).


class NotificationRequest(BaseModel):
    # App Store Server Notification V2: a single JWS in `signedPayload`.
    signedPayload: str


@router.post("/appstore/notifications")
def appstore_notifications(req: NotificationRequest) -> dict:
    # Fail closed on config, but ALWAYS return 2xx to Apple once we've accepted the
    # request, so Apple's retry queue doesn't back up on transient issues.
    try:
        certs = appstore._load_root_certs()  # noqa: SLF001 — internal helper reuse
        from appstoreserverlibrary.models.Environment import Environment
        from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier

        # Notifications may come from either environment; try production then sandbox.
        payload = None
        for env in (Environment.PRODUCTION, Environment.SANDBOX):
            app_apple_id = config.APPSTORE_APP_APPLE_ID if env == Environment.PRODUCTION else None
            if env == Environment.PRODUCTION and app_apple_id is None:
                continue
            try:
                verifier = SignedDataVerifier(
                    certs, False, env, config.APPSTORE_BUNDLE_ID, app_apple_id
                )
                payload = verifier.verify_and_decode_notification(req.signedPayload)
                break
            except Exception:  # noqa: BLE001 — wrong env / parse; try the next
                continue

        if payload is None:
            _log.warning("appstore notification: could not verify signedPayload")
            return {"status": "ignored"}

        _log.info(
            "appstore notification: type=%s subtype=%s uuid=%s",
            getattr(payload, "notificationType", None),
            getattr(payload, "subtype", None),
            getattr(payload, "notificationUUID", None),
        )
        # STUB: full per-type application of the embedded transaction/renewal info
        # to the stored entitlement is the follow-up work described above.
        return {"status": "accepted"}
    except Exception as exc:  # noqa: BLE001
        _log.warning("appstore notification handling failed: %s", exc)
        return {"status": "error"}
