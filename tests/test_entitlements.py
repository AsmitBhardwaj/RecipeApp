"""Server-verified Pro entitlement (app/entitlements.py, app/appstore.py).

Verification against Apple is exercised with a FAKE verifier injected in place of
Apple's SDK, so these run with no Apple keys and no network. Covers: a valid
transaction grants Pro; expired falls back to free; billing grace stays Pro; an
invalid/forged transaction is rejected and grants nothing; wrong bundle/product
id rejected; a Sandbox transaction is accepted by a Production-configured server
(prod-first-then-sandbox); and account binding (appAccountToken must match; one
subscription maps to at most one account, newest wins).
"""
from __future__ import annotations

import os
import tempfile
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest import mock

from fastapi.testclient import TestClient

from app import appstore, config, db, entitlements
from app.appstore import VerifiedTransaction

MONTHLY = "com.recipeapp.RecipeApp2.pro.monthly"


def _dt(days: int) -> datetime:
    return datetime.now(timezone.utc) + timedelta(days=days)


def _vtx(
    *,
    product_id: str = MONTHLY,
    original_transaction_id: str = "otid-1",
    bundle_id: str = "com.recipeapp.RecipeApp2",
    environment: str = "Production",
    expires_at=None,
    app_account_token=None,
    revocation_date=None,
) -> VerifiedTransaction:
    return VerifiedTransaction(
        product_id=product_id,
        original_transaction_id=original_transaction_id,
        bundle_id=bundle_id,
        environment=environment,
        expires_at=expires_at if expires_at is not None else _dt(30),
        app_account_token=app_account_token,
        revocation_date=revocation_date,
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

        self.service = service
        self.user = service.create_email_user("pro@example.com", "pw-123456", "Pro")

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        config.DATABASE_URL = self._orig_url
        try:
            os.remove(self._path)
        except OSError:
            pass


class PolicyTests(_DBBase):
    def test_no_entitlement_is_not_pro(self):
        self.assertFalse(entitlements.is_pro_user(self.user.id))

    def test_anonymous_is_not_pro(self):
        self.assertFalse(entitlements.is_pro_user(None))

    def test_active_is_pro(self):
        with mock.patch.object(appstore, "verify_transaction", return_value=_vtx(expires_at=_dt(30))), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=None):
            status = entitlements.verify_and_store(self.user, "jws")
        self.assertTrue(status.is_pro)
        self.assertTrue(entitlements.is_pro_user(self.user.id))

    def test_expired_falls_back_to_free(self):
        with mock.patch.object(appstore, "verify_transaction", return_value=_vtx(expires_at=_dt(-1))), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=None):
            status = entitlements.verify_and_store(self.user, "jws")
        self.assertFalse(status.is_pro)
        self.assertFalse(entitlements.is_pro_user(self.user.id))

    def test_billing_grace_is_still_pro(self):
        # Subscription itself lapsed, but a 16-day billing grace is still open.
        with mock.patch.object(appstore, "verify_transaction", return_value=_vtx(expires_at=_dt(-1))), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=_dt(10)):
            status = entitlements.verify_and_store(self.user, "jws")
        self.assertTrue(status.is_pro)
        self.assertTrue(entitlements.is_pro_user(self.user.id))

    def test_grace_expired_is_free(self):
        with mock.patch.object(appstore, "verify_transaction", return_value=_vtx(expires_at=_dt(-5))), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=_dt(-1)):
            status = entitlements.verify_and_store(self.user, "jws")
        self.assertFalse(status.is_pro)

    def test_revoked_transaction_grants_nothing(self):
        # A refunded (revoked) transaction expires access immediately.
        with mock.patch.object(appstore, "verify_transaction",
                               return_value=_vtx(expires_at=_dt(30), revocation_date=_dt(-1))), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=None):
            status = entitlements.verify_and_store(self.user, "jws")
        self.assertFalse(status.is_pro)


class RejectionTests(_DBBase):
    def test_invalid_transaction_rejected(self):
        with mock.patch.object(appstore, "verify_transaction",
                               side_effect=appstore.InvalidTransaction("bad sig")):
            with self.assertRaises(entitlements.InvalidTransactionError):
                entitlements.verify_and_store(self.user, "jws")
        self.assertFalse(entitlements.is_pro_user(self.user.id))

    def test_unknown_product_rejected(self):
        with mock.patch.object(appstore, "verify_transaction",
                               return_value=_vtx(product_id="com.someone.else.pro")), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=None):
            with self.assertRaises(entitlements.UnknownProductError):
                entitlements.verify_and_store(self.user, "jws")
        self.assertFalse(entitlements.is_pro_user(self.user.id))

    def test_wrong_bundle_id_rejected(self):
        with mock.patch.object(appstore, "verify_transaction",
                               return_value=_vtx(bundle_id="com.evil.app")), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=None):
            with self.assertRaises(entitlements.InvalidTransactionError):
                entitlements.verify_and_store(self.user, "jws")


class AccountBindingTests(_DBBase):
    def test_app_account_token_must_match_requester(self):
        other = str(uuid.uuid4())  # a different account's UUID
        with mock.patch.object(appstore, "verify_transaction",
                               return_value=_vtx(app_account_token=other)), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=None):
            with self.assertRaises(entitlements.AccountMismatchError):
                entitlements.verify_and_store(self.user, "jws")

    def test_matching_app_account_token_is_accepted(self):
        # Canonical (hyphenated) form of the account id — normalization must match.
        token = str(uuid.UUID(self.user.id))
        with mock.patch.object(appstore, "verify_transaction",
                               return_value=_vtx(app_account_token=token)), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=None):
            status = entitlements.verify_and_store(self.user, "jws")
        self.assertTrue(status.is_pro)

    def test_subscription_moves_to_newest_account_and_revokes_old(self):
        other = self.service.create_email_user("second@example.com", "pw-123456", "Second")
        vtx = _vtx(original_transaction_id="shared-otid")
        with mock.patch.object(appstore, "verify_transaction", return_value=vtx), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=None):
            entitlements.verify_and_store(self.user, "jws")     # account A owns it
            entitlements.verify_and_store(other, "jws")          # account B verifies same sub

        # Newest wins: B is Pro, A is revoked, and the subscription maps to exactly
        # one account.
        self.assertFalse(entitlements.is_pro_user(self.user.id))
        self.assertTrue(entitlements.is_pro_user(other.id))
        owner = db.get_entitlement_by_original_txn("shared-otid")
        self.assertEqual(owner["user_id"], other.id)
        self.assertIsNone(db.get_entitlement(self.user.id))


class EnvironmentFallbackTests(unittest.TestCase):
    """appstore.verify_transaction: Production first, then Sandbox."""

    def setUp(self) -> None:
        appstore._verifier_cache.clear()

    def tearDown(self) -> None:
        appstore._verifier_cache.clear()

    def _payload(self, environment):
        return SimpleNamespace(
            productId=MONTHLY,
            originalTransactionId="otid-sbx",
            bundleId="com.recipeapp.RecipeApp2",
            environment=environment,
            expiresDate=int(_dt(30).timestamp() * 1000),
            appAccountToken=None,
            revocationDate=None,
        )

    def test_sandbox_transaction_accepted_by_production_configured_server(self):
        from appstoreserverlibrary.models.Environment import Environment
        from appstoreserverlibrary.signed_data_verifier import (
            VerificationException,
            VerificationStatus,
        )

        prod = mock.Mock()
        prod.verify_and_decode_signed_transaction.side_effect = VerificationException(
            VerificationStatus.INVALID_ENVIRONMENT
        )
        sandbox = mock.Mock()
        sandbox.verify_and_decode_signed_transaction.return_value = self._payload(Environment.SANDBOX)

        def fake_verifier_for(env):
            return prod if env == Environment.PRODUCTION else sandbox

        with mock.patch.object(appstore, "_verifier_for", side_effect=fake_verifier_for):
            result = appstore.verify_transaction("jws")

        self.assertEqual(result.environment, "Sandbox")
        self.assertEqual(result.product_id, MONTHLY)
        prod.verify_and_decode_signed_transaction.assert_called_once()
        sandbox.verify_and_decode_signed_transaction.assert_called_once()

    def test_invalid_jws_rejected_in_both_environments(self):
        from appstoreserverlibrary.models.Environment import Environment
        from appstoreserverlibrary.signed_data_verifier import (
            VerificationException,
            VerificationStatus,
        )

        failing = mock.Mock()
        failing.verify_and_decode_signed_transaction.side_effect = VerificationException(
            VerificationStatus.VERIFICATION_FAILURE
        )
        with mock.patch.object(appstore, "_verifier_for", return_value=failing):
            with self.assertRaises(appstore.InvalidTransaction):
                appstore.verify_transaction("garbage")


class EndpointTests(_DBBase):
    def setUp(self) -> None:
        super().setUp()
        self._orig_key = config.APP_KEY
        config.APP_KEY = None
        from app.auth import security
        import app.main as main

        self.token, _ = security.create_access_token(self.user.id)
        self.client = TestClient(main.app)

    def tearDown(self) -> None:
        config.APP_KEY = self._orig_key
        super().tearDown()

    def _auth(self):
        return {"Authorization": f"Bearer {self.token}"}

    def test_verify_endpoint_grants_pro(self):
        with mock.patch.object(appstore, "verify_transaction", return_value=_vtx(expires_at=_dt(30))), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=None):
            r = self.client.post(
                "/v1/entitlements/verify",
                json={"signed_transaction": "jws"},
                headers=self._auth(),
            )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertTrue(r.json()["is_pro"])
        self.assertTrue(entitlements.is_pro_user(self.user.id))

    def test_verify_endpoint_requires_auth(self):
        r = self.client.post("/v1/entitlements/verify", json={"signed_transaction": "jws"})
        self.assertEqual(r.status_code, 401)

    def test_verify_endpoint_rejects_invalid_transaction(self):
        with mock.patch.object(appstore, "verify_transaction",
                               side_effect=appstore.InvalidTransaction("bad")):
            r = self.client.post(
                "/v1/entitlements/verify",
                json={"signed_transaction": "forged"},
                headers=self._auth(),
            )
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["detail"]["error_code"], "invalid_transaction")
        self.assertFalse(entitlements.is_pro_user(self.user.id))

    def test_me_endpoint_reports_status(self):
        r = self.client.get("/v1/entitlements/me", headers=self._auth())
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["is_pro"])

    def _seed_recipe_and_job(self):
        from app.models import Job, Nutrition, Recipe

        recipe = Recipe(
            recipe_id="r1",
            canonical_video_id="v1",
            title="Test",
            source_type="caption",
            nutrition=Nutrition(calories=500, basis="per_serving", source="estimated"),
        )
        db.save_recipe(recipe)
        job = Job(
            job_id="j1",
            user_id=self.user.id,
            url="http://x",
            status="complete",
            created_at=datetime.now(timezone.utc).isoformat(),
            recipe_id="r1",
        )
        db.save_job(job)

    def test_nutrition_stripped_for_free_user(self):
        self._seed_recipe_and_job()
        r = self.client.get("/v1/jobs/j1", headers=self._auth())  # no entitlement
        self.assertEqual(r.status_code, 200, r.text)
        self.assertIsNone(r.json()["recipe"]["nutrition"])

    def test_nutrition_present_for_pro_user(self):
        self._seed_recipe_and_job()
        with mock.patch.object(appstore, "verify_transaction", return_value=_vtx(expires_at=_dt(30))), \
             mock.patch.object(appstore, "fetch_grace_expiry", return_value=None):
            entitlements.verify_and_store(self.user, "jws")
        r = self.client.get("/v1/jobs/j1", headers=self._auth())
        self.assertEqual(r.status_code, 200, r.text)
        self.assertIsNotNone(r.json()["recipe"]["nutrition"])
        self.assertEqual(r.json()["recipe"]["nutrition"]["calories"], 500)


if __name__ == "__main__":
    unittest.main()
