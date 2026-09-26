"""Stage 1 auth tests.

DB is a throwaway SQLite file per run (same pattern as the other tests). Provider
verification is exercised OFFLINE: we mint an RS256 token with a locally
generated key and inject the public key, so no call to Apple/Google is made. The
provider ENDPOINTS are tested by stubbing the verifier to return a known
identity — the endpoint's job is upsert + token issuance, verified separately.
"""
from __future__ import annotations

import os
import tempfile
import time
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from sqlalchemy import func, select, text

from app import config, db
from app.auth import providers, service
from app.auth.apple_revocation import RevocationAttempt
from app.auth.providers import ProviderError, VerifiedIdentity
from app.main import app


def _rsa_token(claims: dict):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    token = jwt.encode(claims, key, algorithm="RS256")
    return token, key.public_key()


def _apple_claims(**over):
    now = int(time.time())
    base = {
        "iss": "https://appleid.apple.com",
        "aud": "com.recipeapp.app",
        "sub": "apple-sub-123",
        "email": "person@icloud.com",
        "email_verified": "true",
        "iat": now,
        "exp": now + 600,
    }
    base.update(over)
    return base


class AuthTests(unittest.TestCase):
    def setUp(self):
        self._orig_db = config.DB_PATH
        fd, self._path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        config.DB_PATH = self._path
        db.init_db()
        self._orig_login_limit = config.LOGIN_ATTEMPTS_PER_WINDOW
        self.client = TestClient(app)

    def tearDown(self):
        config.DB_PATH = self._orig_db
        config.LOGIN_ATTEMPTS_PER_WINDOW = self._orig_login_limit
        try:
            os.remove(self._path)
        except OSError:
            pass

    # ---- provider verification (offline) ---------------------------------- #

    def test_verify_apple_extracts_identity(self):
        token, pub = _rsa_token(_apple_claims())
        ident = providers.verify_apple(token, audiences=["com.recipeapp.app"], signing_key=pub)
        self.assertEqual(ident.provider, "apple")
        self.assertEqual(ident.subject, "apple-sub-123")
        self.assertEqual(ident.email, "person@icloud.com")
        self.assertTrue(ident.email_verified)

    def test_verify_rejects_wrong_audience(self):
        token, pub = _rsa_token(_apple_claims(aud="com.someone.else"))
        with self.assertRaises(ProviderError):
            providers.verify_apple(token, audiences=["com.recipeapp.app"], signing_key=pub)

    def test_verify_rejects_wrong_issuer(self):
        token, pub = _rsa_token(_apple_claims(iss="https://evil.example"))
        with self.assertRaises(ProviderError):
            providers.verify_apple(token, audiences=["com.recipeapp.app"], signing_key=pub)

    def test_verify_rejects_expired(self):
        past = int(time.time()) - 10
        token, pub = _rsa_token(_apple_claims(exp=past, iat=past - 600))
        with self.assertRaises(ProviderError):
            providers.verify_apple(token, audiences=["com.recipeapp.app"], signing_key=pub)

    def test_verify_rejects_empty_audience_allowlist(self):
        token, pub = _rsa_token(_apple_claims())
        with self.assertRaises(ProviderError):
            providers.verify_apple(token, audiences=[], signing_key=pub)

    # ---- email / password ------------------------------------------------- #

    def test_register_login_me_flow(self):
        r = self.client.post("/auth/register", json={"email": "a@b.com", "password": "supersecret1", "full_name": "Ada L"})
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        self.assertEqual(body["user"]["email"], "a@b.com")
        self.assertEqual(body["user"]["full_name"], "Ada L")
        self.assertTrue(body["access_token"] and body["refresh_token"])

        me = self.client.get("/auth/me", headers={"Authorization": f"Bearer {body['access_token']}"})
        self.assertEqual(me.status_code, 200)
        self.assertEqual(me.json()["id"], body["user"]["id"])

        login = self.client.post("/auth/login", json={"email": "A@B.com", "password": "supersecret1"})
        self.assertEqual(login.status_code, 200, login.text)
        self.assertEqual(login.json()["user"]["id"], body["user"]["id"])  # email case-insensitive

    def test_duplicate_email_conflicts(self):
        self.client.post("/auth/register", json={"email": "dup@b.com", "password": "supersecret1"})
        r = self.client.post("/auth/register", json={"email": "dup@b.com", "password": "another-one1"})
        self.assertEqual(r.status_code, 409)

    def test_wrong_password_rejected(self):
        self.client.post("/auth/register", json={"email": "c@b.com", "password": "supersecret1"})
        r = self.client.post("/auth/login", json={"email": "c@b.com", "password": "wrongwrong"})
        self.assertEqual(r.status_code, 401)

    def test_me_requires_auth(self):
        self.assertEqual(self.client.get("/auth/me").status_code, 401)
        self.assertEqual(
            self.client.get("/auth/me", headers={"Authorization": "Bearer not.a.token"}).status_code, 401
        )

    def test_login_bruteforce_locks_out(self):
        config.LOGIN_ATTEMPTS_PER_WINDOW = 3
        self.client.post("/auth/register", json={"email": "d@b.com", "password": "supersecret1"})
        for _ in range(3):
            self.client.post("/auth/login", json={"email": "d@b.com", "password": "nope-nope-1"})
        # Next attempt (even with the RIGHT password) is throttled.
        r = self.client.post("/auth/login", json={"email": "d@b.com", "password": "supersecret1"})
        self.assertEqual(r.status_code, 429)

    # ---- refresh rotation ------------------------------------------------- #

    def test_refresh_rotates_and_old_token_dies(self):
        reg = self.client.post("/auth/register", json={"email": "e@b.com", "password": "supersecret1"}).json()
        first = reg["refresh_token"]
        r = self.client.post("/auth/refresh", json={"refresh_token": first})
        self.assertEqual(r.status_code, 200, r.text)
        new = r.json()["refresh_token"]
        self.assertNotEqual(first, new)
        # Reusing the rotated (old) token must fail.
        self.assertEqual(self.client.post("/auth/refresh", json={"refresh_token": first}).status_code, 401)
        # The new token still works.
        self.assertEqual(self.client.post("/auth/refresh", json={"refresh_token": new}).status_code, 200)

    def test_delete_account_removes_user_and_data(self):
        reg = self.client.post(
            "/auth/register", json={"email": "del@b.com", "password": "supersecret1"}
        ).json()
        uid, access, refresh = reg["user"]["id"], reg["access_token"], reg["refresh_token"]
        hdr = {"Authorization": f"Bearer {access}"}

        # Seed every account-attributable table. The recipe row is deliberately
        # shared cache data and must survive after its user association is gone.
        now = datetime.now(timezone.utc).isoformat()
        recipe_id = "shared-recipe"
        with db.get_engine().begin() as conn:
            conn.execute(db.recipes.insert().values(
                recipe_id=recipe_id,
                canonical_video_id="instagram:shared",
                source_url="https://www.instagram.com/reel/shared/",
                source_platform="instagram",
                source_creator="cook",
                data='{"recipe_id":"shared-recipe","canonical_video_id":"instagram:shared","title":"Soup","source_type":"caption","source_url":"https://www.instagram.com/reel/shared/","source_platform":"instagram"}',
            ))
            conn.execute(db.user_recipes.insert().values(
                user_id="deleting-device", recipe_id=recipe_id, account_id=uid,
                custom_name=None, sort_key="", saved_at=now
            ))
            conn.execute(db.user_recipes.insert().values(
                user_id="other-device", recipe_id=recipe_id, account_id="other-account",
                custom_name=None, sort_key="", saved_at=now
            ))
            conn.execute(db.recipes.insert().values(
                recipe_id="exclusive-recipe", canonical_video_id="paste:exclusive",
                source_url=None, source_platform=None, source_creator=None,
                data='{"recipe_id":"exclusive-recipe","canonical_video_id":"paste:exclusive","title":"Mine","source_type":"caption"}',
            ))
            conn.execute(db.user_recipes.insert().values(
                user_id="deleting-device", recipe_id="exclusive-recipe", account_id=uid,
                custom_name=None, sort_key="", saved_at=now
            ))
            conn.execute(db.jobs.insert().values(
                job_id="delete-job", account_id=uid,
                data=f'{{"job_id":"delete-job","user_id":"device","url":"https://example.com","status":"complete","created_at":"{now}","account_id":"{uid}"}}',
            ))
            conn.execute(db.import_events.insert().values(
                job_id="delete-job", account_id=uid, year_month="2026-09", created_at=now
            ))
            conn.execute(db.entitlements.insert().values(
                user_id=uid, product_id="pro.yearly", original_transaction_id="txn-delete",
                pro_expires_at=None, grace_expires_at=None, environment="Sandbox",
                last_verified_at=now, updated_at=now,
            ))
            conn.execute(db.llm_cost_events.insert().values(
                account_id=uid, call_type="import", model="test", prompt_tokens=1,
                cached_tokens=0, completion_tokens=1, estimated_cost_usd=0.01, created_at=now,
            ))
            conn.execute(db.feedback.insert().values(
                account_id=uid, rating=5, message="private feedback", contact_email="del@b.com",
                app_version="1", platform="ios", created_at=now,
            ))
            conn.execute(db.rate_limits.insert().values(
                bucket_key=f"burst:import:{uid}:60", window_start=1, count=1
            ))
            conn.execute(db.apple_revocation_credentials.insert().values(
                user_id=uid, encrypted_refresh_token="encrypted-token", updated_at=now
            ))
            conn.execute(db.auth_identities.insert().values(
                provider="google", subject="delete-subject", user_id=uid,
                email="del@b.com", created_at=now,
            ))
            conn.execute(db.account_device_signals.insert().values(
                account_id="other-account", device_id="other-device", created_at=now,
                flagged=True, related_account_id=uid,
            ))

        # Seed some synced data so we can prove it's gone after deletion.
        push = self.client.post(
            "/v1/sync/push",
            headers=hdr,
            json={"changes": [{"collection": "grocery_manual", "item_id": "g1", "updated_at": 1, "payload": "{}"}]},
        )
        self.assertEqual(push.status_code, 200, push.text)

        # Delete requires a valid access token and returns 204.
        self.assertEqual(self.client.delete("/auth/me").status_code, 401)  # unauthenticated rejected
        with mock.patch(
            "app.auth.router.apple_revocation.revoke_encrypted",
            return_value=RevocationAttempt(False, "revocation_unavailable"),
        ):
            r = self.client.delete("/auth/me", headers=hdr)
        self.assertEqual(r.status_code, 204, r.text)

        # Account is gone: login fails, the (still-unexpired) access token 401s
        # because the user no longer exists, and the refresh token is dead.
        self.assertEqual(
            self.client.post("/auth/login", json={"email": "del@b.com", "password": "supersecret1"}).status_code, 401
        )
        self.assertEqual(self.client.get("/auth/me", headers=hdr).status_code, 401)
        self.assertEqual(self.client.post("/auth/refresh", json={"refresh_token": refresh}).status_code, 401)

        # Synced data for the deleted user is gone.
        self.assertEqual(db.sync_pull(uid, 0, 100)["changes"], [])
        with db.get_engine().begin() as conn:
            for table, column in (
                (db.user_recipes, db.user_recipes.c.account_id),
                (db.jobs, db.jobs.c.account_id),
                (db.import_events, db.import_events.c.account_id),
                (db.entitlements, db.entitlements.c.user_id),
                (db.llm_cost_events, db.llm_cost_events.c.account_id),
                (db.feedback, db.feedback.c.account_id),
                (db.apple_revocation_credentials, db.apple_revocation_credentials.c.user_id),
                (db.auth_identities, db.auth_identities.c.user_id),
                (db.refresh_tokens, db.refresh_tokens.c.user_id),
                (db.users, db.users.c.id),
            ):
                self.assertEqual(conn.execute(
                    select(func.count()).select_from(table).where(column == uid)
                ).scalar_one(), 0, table.name)
            self.assertEqual(conn.execute(
                select(func.count()).select_from(db.rate_limits).where(db.rate_limits.c.bucket_key.contains(uid))
            ).scalar_one(), 0)
            self.assertEqual(conn.execute(
                select(func.count()).select_from(db.recipes).where(db.recipes.c.recipe_id == recipe_id)
            ).scalar_one(), 1)
            self.assertEqual(conn.execute(
                select(func.count()).select_from(db.recipes).where(
                    db.recipes.c.recipe_id == "exclusive-recipe"
                )
            ).scalar_one(), 0)
            retry = conn.execute(select(db.apple_revocation_tasks)).mappings().one()
            self.assertEqual(retry["last_error_code"], "revocation_unavailable")
            self.assertNotIn(uid, retry["encrypted_refresh_token"])
            related = conn.execute(
                select(db.account_device_signals).where(
                    db.account_device_signals.c.account_id == "other-account"
                )
            ).mappings().one()
            self.assertIsNone(related["related_account_id"])
            self.assertFalse(related["flagged"])

        # Re-registering the same email yields a brand-new, empty account.
        again = self.client.post(
            "/auth/register", json={"email": "del@b.com", "password": "supersecret1"}
        ).json()
        self.assertNotEqual(again["user"]["id"], uid)

    def test_delete_account_rolls_back_atomically(self):
        reg = self.client.post(
            "/auth/register", json={"email": "atomic@b.com", "password": "supersecret1"}
        ).json()
        uid = reg["user"]["id"]
        now = datetime.now(timezone.utc).isoformat()
        with db.get_engine().begin() as conn:
            conn.execute(db.jobs.insert().values(
                job_id="atomic-job", account_id=uid,
                data=f'{{"job_id":"atomic-job","user_id":"device","url":"https://example.com","status":"complete","created_at":"{now}","account_id":"{uid}"}}',
            ))
            conn.execute(text(
                "CREATE TRIGGER abort_atomic_delete BEFORE DELETE ON users "
                "BEGIN SELECT RAISE(ABORT, 'forced rollback'); END"
            ))

        with self.assertRaises(Exception):
            db.delete_account(uid)

        with db.get_engine().begin() as conn:
            self.assertEqual(conn.execute(
                select(func.count()).select_from(db.users).where(db.users.c.id == uid)
            ).scalar_one(), 1)
            self.assertEqual(conn.execute(
                select(func.count()).select_from(db.jobs).where(db.jobs.c.account_id == uid)
            ).scalar_one(), 1)

    # ---- provider endpoints (verifier stubbed) ---------------------------- #

    def test_apple_endpoint_upserts_and_is_stable(self, ):
        ident = VerifiedIdentity(provider="apple", subject="sub-xyz", email="p@icloud.com", email_verified=True)
        orig = providers.verify_apple
        providers.verify_apple = lambda token, **kw: ident
        # router imported the symbol; patch there too
        from app.auth import router as auth_router
        auth_router.providers.verify_apple = lambda token, **kw: ident
        try:
            with mock.patch(
                "app.auth.router.apple_revocation.exchange_authorization_code",
                return_value="apple-refresh",
            ), mock.patch(
                "app.auth.router.apple_revocation.encrypt_refresh_token",
                return_value="encrypted-apple-refresh",
            ), mock.patch("app.auth.router.db.store_apple_revocation_credential") as store:
                r1 = self.client.post("/auth/apple", json={
                    "identity_token": "tok", "authorization_code": "code-1", "full_name": "Grace H"
                })
                self.assertEqual(r1.status_code, 200, r1.text)
                uid1 = r1.json()["user"]["id"]
                store.assert_called_once_with(uid1, "encrypted-apple-refresh")
                # Second sign-in, no name this time → same account, name preserved.
                r2 = self.client.post("/auth/apple", json={
                    "identity_token": "tok", "authorization_code": "code-2"
                })
            self.assertEqual(r1.json()["user"]["full_name"], "Grace H")
            self.assertEqual(r2.json()["user"]["id"], uid1)
            self.assertEqual(r2.json()["user"]["full_name"], "Grace H")
        finally:
            providers.verify_apple = orig
            auth_router.providers.verify_apple = orig

    def test_provider_links_to_existing_email_account(self):
        # Email account first.
        reg = self.client.post("/auth/register", json={"email": "link@me.com", "password": "supersecret1"}).json()
        uid = reg["user"]["id"]
        # Google sign-in with the SAME verified email → same account, not a dup.
        ident = VerifiedIdentity(provider="google", subject="g-sub-1", email="link@me.com", email_verified=True)
        from app.auth import router as auth_router
        orig = auth_router.providers.verify_google
        auth_router.providers.verify_google = lambda token, **kw: ident
        try:
            r = self.client.post("/auth/google", json={"id_token": "tok"})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertEqual(r.json()["user"]["id"], uid)
        finally:
            auth_router.providers.verify_google = orig


if __name__ == "__main__":
    unittest.main()
