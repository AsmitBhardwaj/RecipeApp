"""App Store Server Notifications V2 (app/entitlements.apply_notification + the
POST /v1/appstore/notifications endpoint).

Signature verification is mocked (parse_notification returns a ParsedNotification),
so these run with no Apple keys/network. Each subscription-lifecycle type is
applied to a stored entitlement and the resulting Pro state asserted; handling is
idempotent (Apple retries) and unknown subscriptions are ignored.
"""
from __future__ import annotations

import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

from fastapi.testclient import TestClient

from app import appstore, config, db, entitlements
from app.appstore import ParsedNotification

MONTHLY = "com.recipeapp.RecipeApp2.pro.monthly"
OTID = "sub-1"


def _dt(days: int) -> datetime:
    return datetime.now(timezone.utc) + timedelta(days=days)


def _iso(days):
    return _dt(days).isoformat() if days is not None else None


def _pn(
    notification_type: str,
    *,
    subtype=None,
    otid: str = OTID,
    expires_days=None,
    grace_days=None,
    revoked_days=None,
    product: str = MONTHLY,
) -> ParsedNotification:
    return ParsedNotification(
        notification_type=notification_type,
        subtype=subtype,
        notification_uuid="uuid-1",
        environment="Production",
        original_transaction_id=otid,
        product_id=product,
        expires_at=_dt(expires_days) if expires_days is not None else None,
        revocation_date=_dt(revoked_days) if revoked_days is not None else None,
        grace_expires_at=_dt(grace_days) if grace_days is not None else None,
    )


class _DBBase(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_db = config.DB_PATH
        self._orig_url = config.DATABASE_URL
        fd, self._path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        config.DB_PATH = self._path
        config.DATABASE_URL = None
        db.init_db()
        from app.auth import service

        self.user = service.create_email_user("owner@example.com", "pw-123456", "Owner")

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        config.DATABASE_URL = self._orig_url
        try:
            os.remove(self._path)
        except OSError:
            pass

    def _seed(self, *, pro_days=None, grace_days=None, otid: str = OTID) -> None:
        now = datetime.now(timezone.utc).isoformat()
        db.upsert_entitlement(
            user_id=self.user.id,
            product_id=MONTHLY,
            original_transaction_id=otid,
            pro_expires_at=_iso(pro_days),
            grace_expires_at=_iso(grace_days),
            environment="Production",
            last_verified_at=now,
            updated_at=now,
        )


class ApplyNotificationTests(_DBBase):
    def test_did_renew_extends_and_clears_grace(self):
        self._seed(pro_days=-1, grace_days=5)  # lapsed, was in grace
        action = entitlements.apply_notification(_pn("DID_RENEW", expires_days=30))
        self.assertEqual(action, "applied:DID_RENEW")
        rec = db.get_entitlement(self.user.id)
        self.assertTrue(entitlements.is_pro_user(self.user.id))
        self.assertIsNone(rec["grace_expires_at"])

    def test_expired_ends_access(self):
        self._seed(pro_days=10)
        entitlements.apply_notification(_pn("EXPIRED", expires_days=-1))
        self.assertFalse(entitlements.is_pro_user(self.user.id))

    def test_did_fail_to_renew_with_grace_stays_pro(self):
        self._seed(pro_days=-1)  # renewal failed, subscription itself lapsed
        entitlements.apply_notification(
            _pn("DID_FAIL_TO_RENEW", subtype="GRACE_PERIOD", grace_days=16)
        )
        self.assertTrue(entitlements.is_pro_user(self.user.id))

    def test_did_fail_to_renew_without_grace_is_not_pro(self):
        self._seed(pro_days=-1)  # billing retry, no grace window
        entitlements.apply_notification(_pn("DID_FAIL_TO_RENEW", subtype="BILLING_RETRY"))
        self.assertFalse(entitlements.is_pro_user(self.user.id))

    def test_grace_period_expired_drops_grace(self):
        self._seed(pro_days=-2, grace_days=3)  # currently Pro via grace
        self.assertTrue(entitlements.is_pro_user(self.user.id))
        entitlements.apply_notification(_pn("GRACE_PERIOD_EXPIRED"))
        self.assertFalse(entitlements.is_pro_user(self.user.id))

    def test_refund_ends_access(self):
        self._seed(pro_days=30)
        entitlements.apply_notification(_pn("REFUND", revoked_days=-1))
        self.assertFalse(entitlements.is_pro_user(self.user.id))

    def test_revoke_ends_access(self):
        self._seed(pro_days=30)
        entitlements.apply_notification(_pn("REVOKE"))
        self.assertFalse(entitlements.is_pro_user(self.user.id))

    def test_did_change_renewal_status_keeps_access(self):
        self._seed(pro_days=20)
        action = entitlements.apply_notification(
            _pn("DID_CHANGE_RENEWAL_STATUS", subtype="AUTO_RENEW_DISABLED", expires_days=20)
        )
        self.assertEqual(action, "applied:DID_CHANGE_RENEWAL_STATUS")
        self.assertTrue(entitlements.is_pro_user(self.user.id))

    def test_apply_is_idempotent(self):
        self._seed(pro_days=-1)
        pn = _pn("DID_RENEW", expires_days=30)
        entitlements.apply_notification(pn)
        first = db.get_entitlement(self.user.id)["pro_expires_at"]
        entitlements.apply_notification(pn)  # Apple redelivers
        second = db.get_entitlement(self.user.id)["pro_expires_at"]
        self.assertEqual(first, second)
        self.assertTrue(entitlements.is_pro_user(self.user.id))

    def test_unknown_subscription_is_ignored(self):
        # No row for this otid → nothing created, nothing granted.
        action = entitlements.apply_notification(_pn("DID_RENEW", otid="never-seen", expires_days=30))
        self.assertEqual(action, "ignored_unknown_subscription")
        self.assertIsNone(db.get_entitlement_by_original_txn("never-seen"))

    def test_missing_transaction_is_ignored(self):
        action = entitlements.apply_notification(
            ParsedNotification("TEST", None, "u", "Production", None, None, None, None, None)
        )
        self.assertEqual(action, "ignored_no_transaction")

    def test_unhandled_type_is_ignored(self):
        self._seed(pro_days=30)
        action = entitlements.apply_notification(_pn("PRICE_INCREASE"))
        self.assertEqual(action, "ignored_type:PRICE_INCREASE")
        self.assertTrue(entitlements.is_pro_user(self.user.id))  # unchanged


class EndpointTests(_DBBase):
    def setUp(self) -> None:
        super().setUp()
        self._orig_key = config.APP_KEY
        config.APP_KEY = None
        import app.main as main

        self.client = TestClient(main.app)

    def tearDown(self) -> None:
        config.APP_KEY = self._orig_key
        super().tearDown()

    def test_endpoint_applies_notification_and_returns_200(self):
        self._seed(pro_days=-1)
        with mock.patch.object(appstore, "parse_notification",
                               return_value=_pn("DID_RENEW", expires_days=30)):
            r = self.client.post("/v1/appstore/notifications", json={"signedPayload": "jws"})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["action"], "applied:DID_RENEW")
        self.assertTrue(entitlements.is_pro_user(self.user.id))

    def test_endpoint_no_auth_required(self):
        # Apple posts unauthenticated; the signature is the auth.
        with mock.patch.object(appstore, "parse_notification",
                               return_value=_pn("DID_RENEW", otid="never-seen", expires_days=30)):
            r = self.client.post("/v1/appstore/notifications", json={"signedPayload": "jws"})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["action"], "ignored_unknown_subscription")

    def test_endpoint_rejects_invalid_signature(self):
        with mock.patch.object(appstore, "parse_notification",
                               side_effect=appstore.InvalidNotification("bad sig")):
            r = self.client.post("/v1/appstore/notifications", json={"signedPayload": "forged"})
        self.assertEqual(r.status_code, 400)


if __name__ == "__main__":
    unittest.main()
