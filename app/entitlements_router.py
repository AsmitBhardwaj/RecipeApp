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

from . import appstore, entitlements
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
# App Store Server Notifications V2
# --------------------------------------------------------------------------- #
#
# Apple POSTs subscription lifecycle events (renew / expire / billing grace /
# refund / revoke / renewal-status change) as a single signed JWS. We verify it
# against the bundled Apple root certs and apply it to the stored entitlement so
# the server reflects the subscription without waiting for the client to
# re-verify. Handling is idempotent (Apple retries and can redeliver), and we
# return 200 quickly.
#
# SETUP: enter this URL in App Store Connect → your app → App Information →
# "App Store Server Notifications", for BOTH the Production and Sandbox Version 2
# URLs: https://recipeapp-production-3a60.up.railway.app/v1/appstore/notifications


class NotificationRequest(BaseModel):
    # App Store Server Notification V2: a single JWS in `signedPayload`.
    signedPayload: str


@router.post("/appstore/notifications")
def appstore_notifications(req: NotificationRequest) -> dict:
    # Verify the Apple signature, then apply. We return 200 for anything we
    # successfully verified (Apple should not retry a delivered notification), and
    # 400 only when the signature itself doesn't verify. The work is a couple of
    # verifies + one idempotent DB write — fast enough to answer inline.
    try:
        parsed = appstore.parse_notification(req.signedPayload)
    except appstore.InvalidNotification as exc:
        _log.warning("appstore notification failed verification: %s", exc)
        raise HTTPException(status_code=400, detail="invalid signedPayload")
    except Exception as exc:  # noqa: BLE001 — config/parse error: let Apple retry
        _log.error("appstore notification verify error: %s", exc)
        raise HTTPException(status_code=500, detail="notification processing error")

    try:
        action = entitlements.apply_notification(parsed)
    except Exception as exc:  # noqa: BLE001 — transient DB error: 500 so Apple retries
        _log.error(
            "appstore notification apply failed (type=%s uuid=%s): %s",
            parsed.notification_type, parsed.notification_uuid, exc,
        )
        raise HTTPException(status_code=500, detail="notification apply error")

    _log.info(
        "appstore notification type=%s subtype=%s uuid=%s -> %s",
        parsed.notification_type, parsed.subtype, parsed.notification_uuid, action,
    )
    return {"status": "ok", "action": action}
