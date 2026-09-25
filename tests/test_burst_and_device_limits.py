"""Per-account burst/daily caps (app/burstlimit.py) and the device-level
account-creation signal (app/devicesignal.py).

Covers the four cases the spec calls out:
  * BURST-BEFORE-DAILY — the tighter (per-hour) import window trips before the
    per-day one when a client bursts.
  * DAILY RESET — the per-day counter resets at the UTC day boundary.
  * PRO STILL BOUNDED — a Pro account hits the burst/daily import caps (429 +
    rate_limit_exceeded) but is NEVER shown the paywall (402 free_limit_reached).
  * DEVICE FLAGGING — a new account created from a device that already created
    another account within the trailing window is flagged (advisory, not blocked).

Unit tests drive the limiter/signal directly against a throwaway SQLite file;
endpoint tests go through FastAPI with the pipeline/LLM stubbed so no real work
runs.

    DATABASE_URL= python3 -m unittest tests.test_burst_and_device_limits
"""
from __future__ import annotations

import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

from fastapi.testclient import TestClient

from app import burstlimit, config, db, devicesignal
from app.auth.providers import VerifiedIdentity
from tests.entitlement_utils import grant_pro, revoke_pro


def _fresh_db() -> str:
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    return path


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def _days_ago(n: int) -> str:
    return _iso(datetime.now(timezone.utc) - timedelta(days=n))


class _DBBase(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_db = config.DB_PATH
        self._orig_url = config.DATABASE_URL
        self._path = _fresh_db()
        config.DB_PATH = self._path
        config.DATABASE_URL = None  # force the local sqlite path
        db.init_db()

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        config.DATABASE_URL = self._orig_url
        os.unlink(self._path)


# --------------------------------------------------------------------------- #
# Burst / daily limiter — unit level
# --------------------------------------------------------------------------- #


class BurstLimiterTests(_DBBase):
    def setUp(self) -> None:
        super().setUp()
        self._orig = {
            k: getattr(config, k)
            for k in (
                "BURST_IMPORT_PER_HOUR",
                "BURST_IMPORT_PER_DAY",
                "BURST_BUDGET_PLAN_PER_DAY",
                "BURST_PANTRY_PER_DAY",
            )
        }

    def tearDown(self) -> None:
        for k, v in self._orig.items():
            setattr(config, k, v)
        super().tearDown()

    def _allowed_imports(self, calls: int, account: str = "acct-A") -> int:
        n = 0
        for _ in range(calls):
            try:
                burstlimit.check_import(account)
                n += 1
            except burstlimit.BurstLimitExceeded:
                break
        return n

    def test_burst_triggers_before_daily(self) -> None:
        # Tight hour window (2), roomy day window (100): the 3rd call in the hour
        # trips the HOUR rule first — the daily cap is nowhere near.
        config.BURST_IMPORT_PER_HOUR = 2
        config.BURST_IMPORT_PER_DAY = 100
        self.assertEqual(self._allowed_imports(2), 2)
        with self.assertRaises(burstlimit.BurstLimitExceeded) as ctx:
            burstlimit.check_import("acct-A")
        self.assertEqual(ctx.exception.window_label, "hour")
        self.assertEqual(ctx.exception.limit, 2)
        self.assertEqual(ctx.exception.code, "rate_limit_exceeded")

    def test_daily_trips_when_hour_is_generous(self) -> None:
        # Inverse: roomy hour, tight day → the DAY rule is what trips.
        config.BURST_IMPORT_PER_HOUR = 100
        config.BURST_IMPORT_PER_DAY = 2
        self.assertEqual(self._allowed_imports(2), 2)
        with self.assertRaises(burstlimit.BurstLimitExceeded) as ctx:
            burstlimit.check_import("acct-A")
        self.assertEqual(ctx.exception.window_label, "day")
        self.assertEqual(ctx.exception.limit, 2)

    def test_daily_limit_resets_at_day_boundary(self) -> None:
        # Pin wall-clock time so we control the UTC-aligned day bucket. Day N is
        # exhausted; advancing exactly one day past the boundary starts a fresh
        # bucket and allows again.
        config.BURST_PANTRY_PER_DAY = 2
        # A timestamp sitting well inside a UTC day (noon of an arbitrary day).
        day0_noon = 1_600_000_000  # fixed epoch inside some UTC day
        with mock.patch("app.burstlimit.time.time", return_value=day0_noon):
            burstlimit.check_pantry("acct-A")
            burstlimit.check_pantry("acct-A")
            with self.assertRaises(burstlimit.BurstLimitExceeded):
                burstlimit.check_pantry("acct-A")  # 3rd same-day call blocked
        # Advance 24h → next UTC day → counter reset → allowed again.
        with mock.patch("app.burstlimit.time.time", return_value=day0_noon + 86_400):
            burstlimit.check_pantry("acct-A")  # must NOT raise
            burstlimit.check_pantry("acct-A")
            with self.assertRaises(burstlimit.BurstLimitExceeded):
                burstlimit.check_pantry("acct-A")

    def test_accounts_have_independent_buckets(self) -> None:
        config.BURST_IMPORT_PER_HOUR = 2
        config.BURST_IMPORT_PER_DAY = 100
        self.assertEqual(self._allowed_imports(2, account="A"), 2)
        self.assertEqual(self._allowed_imports(2, account="B"), 2)  # B unaffected by A

    def test_scopes_are_independent(self) -> None:
        # Exhausting the import cap must not consume the budget or pantry allowance.
        config.BURST_IMPORT_PER_HOUR = 1
        config.BURST_IMPORT_PER_DAY = 1
        config.BURST_BUDGET_PLAN_PER_DAY = 1
        config.BURST_PANTRY_PER_DAY = 1
        burstlimit.check_import("acct-A")
        with self.assertRaises(burstlimit.BurstLimitExceeded):
            burstlimit.check_import("acct-A")
        # Different scopes still have their full, separate allowance.
        burstlimit.check_budget_plan("acct-A")  # no raise
        burstlimit.check_pantry("acct-A")       # no raise


# --------------------------------------------------------------------------- #
# Import burst cap — endpoint level (Pro still bounded, never paywalled)
# --------------------------------------------------------------------------- #


class ImportBurstEndpointTests(_DBBase):
    def setUp(self) -> None:
        super().setUp()
        from app.auth import security, service
        import app.main as main
        from app.models import Job

        self._orig_key = config.APP_KEY
        self._orig_burst = (config.BURST_IMPORT_PER_HOUR, config.BURST_IMPORT_PER_DAY)
        self._orig_ratelimits = {
            k: getattr(config, k)
            for k in (
                "RATE_LIMIT_USER_PER_MIN",
                "RATE_LIMIT_USER_PER_HOUR",
                "RATE_LIMIT_IP_PER_MIN",
                "RATE_LIMIT_IP_PER_HOUR",
            )
        }
        config.APP_KEY = None  # fail-open
        # Keep the generic per-user/IP limiter out of the way so we isolate the
        # per-account burst cap.
        for k in self._orig_ratelimits:
            setattr(config, k, 100000)
        # Tight burst cap so a couple of requests trip it.
        config.BURST_IMPORT_PER_HOUR = 2
        config.BURST_IMPORT_PER_DAY = 100
        # Effective date in the PAST so the free monthly cap is live (not
        # grandfathered) — this lets us prove Pro sidesteps 402 but still hits 429.
        self._orig_effective = config.FREE_LIMIT_EFFECTIVE_DATE
        self._orig_free = config.FREE_IMPORT_LIMIT
        config.FREE_LIMIT_EFFECTIVE_DATE = "2000-01-01T00:00:00+00:00"
        config.FREE_IMPORT_LIMIT = 1

        self.user = service.create_email_user("burst@example.com", "pw-123456", "Burst")
        self.token, _ = security.create_access_token(self.user.id)

        self.main = main
        self._orig_create = main.orchestrator.create_job
        self._orig_process = main.orchestrator.process_job
        main.orchestrator.create_job = lambda url, uid, account_id=None: Job(
            job_id="stub",
            user_id=uid,
            account_id=account_id,
            url=url,
            canonical_video_id="v1",
            platform="instagram",
            status="queued",
            created_at=datetime.now(timezone.utc).isoformat(),
        )
        main.orchestrator.process_job = lambda job: None
        self.client = TestClient(main.app)

    def tearDown(self) -> None:
        config.APP_KEY = self._orig_key
        config.BURST_IMPORT_PER_HOUR, config.BURST_IMPORT_PER_DAY = self._orig_burst
        config.FREE_LIMIT_EFFECTIVE_DATE = self._orig_effective
        config.FREE_IMPORT_LIMIT = self._orig_free
        for k, v in self._orig_ratelimits.items():
            setattr(config, k, v)
        self.main.orchestrator.create_job = self._orig_create
        self.main.orchestrator.process_job = self._orig_process
        super().tearDown()

    def _headers(self, pro: bool) -> dict:
        # Pro is a server-verified stored entitlement now — seed/clear it to match.
        if pro:
            grant_pro(self.user.id)
        else:
            revoke_pro(self.user.id)
        return {"Authorization": f"Bearer {self.token}", "X-User-Id": "device-1"}

    def test_pro_hits_burst_but_never_paywall(self) -> None:
        h = self._headers(pro=True)
        # Pro removes the monthly cap: the first two imports succeed even though
        # FREE_IMPORT_LIMIT is 1 (a free user would be paywalled at the 2nd).
        codes = [
            self.client.post("/v1/jobs", json={"url": "http://x"}, headers=h).status_code
            for _ in range(2)
        ]
        self.assertEqual(codes, [200, 200])
        # 3rd trips the burst cap → 429 with the distinct rate_limit_exceeded code,
        # NOT the 402 paywall.
        r = self.client.post("/v1/jobs", json={"url": "http://x"}, headers=h)
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["detail"]["error_code"], "rate_limit_exceeded")

    def test_free_user_sees_paywall_before_burst(self) -> None:
        # A free account already at the monthly cap gets the paywall (402), not the
        # burst 429 — proving the monthly cap is evaluated first for free users.
        # (The stubbed pipeline never runs _finalize, so seed the ledger directly,
        # like the import-limit endpoint tests do.)
        from app import importlimit

        month = importlimit.month_key(datetime.now(timezone.utc))
        db.record_import_event(self.user.id, "seed-0", month, datetime.now(timezone.utc).isoformat())
        r = self.client.post("/v1/jobs", json={"url": "http://x"}, headers=self._headers(pro=False))
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["detail"]["error_code"], "free_limit_reached")

    def test_unauthenticated_import_is_rejected(self) -> None:
        # /v1/jobs now requires a valid session token (current_user): with no token
        # every attempt is 401 — no account is ever created, so no LLM work runs.
        h = {"X-User-Id": "device-anon"}
        codes = [
            self.client.post("/v1/jobs", json={"url": "http://x"}, headers=h).status_code
            for _ in range(5)
        ]
        self.assertTrue(all(c == 401 for c in codes), codes)

    def test_paste_path_is_burst_limited(self) -> None:
        h = self._headers(pro=True)
        # Burn the two-per-hour allowance on the paste endpoint itself.
        for _ in range(2):
            self.client.post("/v1/jobs/none/paste", json={"text": "x" * 40}, headers=h)
        r = self.client.post("/v1/jobs/none/paste", json={"text": "x" * 40}, headers=h)
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["detail"]["error_code"], "rate_limit_exceeded")


# --------------------------------------------------------------------------- #
# Budget-plan & pantry per-day caps — endpoint level
# --------------------------------------------------------------------------- #


class BudgetAndPantryCapTests(_DBBase):
    def setUp(self) -> None:
        super().setUp()
        from app.auth import security, service
        import app.main as main

        self._orig_key = config.APP_KEY
        self._orig_budget = config.BURST_BUDGET_PLAN_PER_DAY
        self._orig_pantry = config.BURST_PANTRY_PER_DAY
        self._orig_min = config.MIN_BUDGET_PER_PERSON
        config.APP_KEY = None
        config.MIN_BUDGET_PER_PERSON = 25
        config.BURST_BUDGET_PLAN_PER_DAY = 1
        config.BURST_PANTRY_PER_DAY = 1

        self.user = service.create_email_user("caps@example.com", "pw-123456", "Caps")
        self.token, _ = security.create_access_token(self.user.id)
        # Budget + pantry are Pro-gated; seed a verified entitlement so these
        # tests exercise the per-day CAP, not the paywall.
        grant_pro(self.user.id)
        self.main = main
        self.client = TestClient(main.app)

    def tearDown(self) -> None:
        config.APP_KEY = self._orig_key
        config.BURST_BUDGET_PLAN_PER_DAY = self._orig_budget
        config.BURST_PANTRY_PER_DAY = self._orig_pantry
        config.MIN_BUDGET_PER_PERSON = self._orig_min
        super().tearDown()

    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self.token}",
            "X-User-Id": "device-1",
        }

    def _budget_body(self) -> dict:
        return {
            "budget": 100,
            "currency": "USD",
            "household_size": 2,
            "dietary_preferences": [],
            "pantry_items": ["rice", "eggs"],
            "country": "US",
            "area_type": "suburb",
        }

    def _fake_recipes(self):
        from app.models import CostEstimate, LLMRecipe
        from app.pipeline.llm import BudgetPlanRecipeLLM

        return [
            BudgetPlanRecipeLLM(
                recipe=LLMRecipe(title="Fried Rice", ingredients=[], instructions=[]),
                baseline_cost=CostEstimate(amount=10.0, currency="USD", basis="llm-v1"),
                health_signal="Veg-forward",
            )
        ]

    def test_budget_plan_daily_cap(self) -> None:
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=self._fake_recipes()):
            first = self.client.post(
                "/v1/meal-plan/budget", json=self._budget_body(), headers=self._headers()
            )
            self.assertEqual(first.status_code, 200, first.text)
            second = self.client.post(
                "/v1/meal-plan/budget", json=self._budget_body(), headers=self._headers()
            )
        self.assertEqual(second.status_code, 429)
        self.assertEqual(second.json()["detail"]["error_code"], "rate_limit_exceeded")

    def test_pantry_daily_cap(self) -> None:
        # Empty pantry override → no LLM call, but the cap is still counted first.
        body = {"pantry_override": ["rice", "eggs"], "allow_generation": False}
        with mock.patch("app.pantry.build_suggestions") as build:
            from app.pantry import SuggestionsResponse

            build.return_value = SuggestionsResponse(
                matches=[], generated=[], pantry_used=[], counts={"cache": 0, "generated": 0}
            )
            first = self.client.post("/v1/pantry/suggestions", json=body, headers=self._headers())
            self.assertEqual(first.status_code, 200, first.text)
            second = self.client.post("/v1/pantry/suggestions", json=body, headers=self._headers())
        self.assertEqual(second.status_code, 429)
        self.assertEqual(second.json()["detail"]["error_code"], "rate_limit_exceeded")


# --------------------------------------------------------------------------- #
# Device-level account-creation signal
# --------------------------------------------------------------------------- #


class DeviceSignalTests(_DBBase):
    def setUp(self) -> None:
        super().setUp()
        self._orig_window = config.DEVICE_MULTI_ACCOUNT_WINDOW_DAYS
        config.DEVICE_MULTI_ACCOUNT_WINDOW_DAYS = 30

    def tearDown(self) -> None:
        config.DEVICE_MULTI_ACCOUNT_WINDOW_DAYS = self._orig_window
        super().tearDown()

    def test_first_account_on_device_is_not_flagged(self) -> None:
        flagged = devicesignal.record_new_account("acct-1", "dev-1", _iso(datetime.now(timezone.utc)))
        self.assertFalse(flagged)
        sig = db.get_account_device_signal("acct-1")
        self.assertIsNotNone(sig)
        self.assertFalse(sig["flagged"])
        self.assertIsNone(sig["related_account_id"])

    def test_second_account_same_device_within_window_is_flagged(self) -> None:
        # A prior account on the same device, created 10 days ago (inside 30d).
        db.record_account_device_signal("acct-old", "dev-1", _days_ago(10), False, None)
        flagged = devicesignal.record_new_account("acct-new", "dev-1", _iso(datetime.now(timezone.utc)))
        self.assertTrue(flagged)
        sig = db.get_account_device_signal("acct-new")
        self.assertTrue(sig["flagged"])
        self.assertEqual(sig["related_account_id"], "acct-old")
        # And it shows up in the queryable review list.
        flagged_ids = [r["account_id"] for r in db.list_flagged_accounts()]
        self.assertIn("acct-new", flagged_ids)
        self.assertNotIn("acct-old", flagged_ids)

    def test_prior_account_outside_window_is_not_flagged(self) -> None:
        db.record_account_device_signal("acct-old", "dev-1", _days_ago(40), False, None)
        flagged = devicesignal.record_new_account("acct-new", "dev-1", _iso(datetime.now(timezone.utc)))
        self.assertFalse(flagged)

    def test_different_devices_do_not_correlate(self) -> None:
        db.record_account_device_signal("acct-old", "dev-1", _days_ago(1), False, None)
        flagged = devicesignal.record_new_account("acct-new", "dev-2", _iso(datetime.now(timezone.utc)))
        self.assertFalse(flagged)

    def test_missing_device_id_never_flags_or_correlates(self) -> None:
        # Two accounts created without a device id must NOT be treated as the same
        # device (null != null), so neither is flagged.
        f1 = devicesignal.record_new_account("acct-a", None, _iso(datetime.now(timezone.utc)))
        f2 = devicesignal.record_new_account("acct-b", "", _iso(datetime.now(timezone.utc)))
        self.assertFalse(f1)
        self.assertFalse(f2)
        self.assertEqual(db.list_flagged_accounts(), [])

    def test_create_email_user_flags_repeat_device(self) -> None:
        from app.auth import service

        a = service.create_email_user("a@example.com", "pw-123456", None, device_id="shared-dev")
        b = service.create_email_user("b@example.com", "pw-123456", None, device_id="shared-dev")
        self.assertFalse(db.get_account_device_signal(a.id)["flagged"])
        sig_b = db.get_account_device_signal(b.id)
        self.assertTrue(sig_b["flagged"])
        self.assertEqual(sig_b["related_account_id"], a.id)

    def test_provider_signup_records_signal_returning_login_does_not_recreate(self) -> None:
        from app.auth import service

        ident = VerifiedIdentity(provider="google", subject="sub-1", email=None, email_verified=False)
        u1 = service.upsert_provider_user(ident, None, device_id="prov-dev")
        # First provider signup recorded a (non-flagged) signal.
        self.assertIsNotNone(db.get_account_device_signal(u1.id))
        self.assertFalse(db.get_account_device_signal(u1.id)["flagged"])
        # A returning login with the SAME identity resolves the same account and
        # must not create a second (spurious) account/signal.
        u2 = service.upsert_provider_user(ident, None, device_id="prov-dev")
        self.assertEqual(u1.id, u2.id)
        # A DIFFERENT account created on the same device now flags — proving the
        # provider path did register the device.
        flagged = devicesignal.record_new_account("acct-x", "prov-dev", _iso(datetime.now(timezone.utc)))
        self.assertTrue(flagged)


if __name__ == "__main__":
    unittest.main()
