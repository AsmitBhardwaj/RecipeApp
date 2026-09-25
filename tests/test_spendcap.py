"""Hard per-account 30-day spend cap (app/spendcap.py + its endpoint enforcement).

    DATABASE_URL= python3 -m unittest tests.test_spendcap

Unit tests drive `spendcap.check` against a throwaway SQLite ledger; the endpoint
test proves /v1/jobs returns 429 (spend_cap_reached) and does NO pipeline work
once an account is over the trailing-30-day cap.
"""
from __future__ import annotations

import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

from app import config, db, spendcap


def _fresh_db() -> str:
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    return path


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat()


class _DBBase(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_db = config.DB_PATH
        self._orig_url = config.DATABASE_URL
        self._orig_cap = config.PER_ACCOUNT_30D_SPEND_CAP_USD
        config.DATABASE_URL = None  # force local sqlite
        self._path = _fresh_db()
        config.DB_PATH = self._path
        db.init_db()

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        config.DATABASE_URL = self._orig_url
        config.PER_ACCOUNT_30D_SPEND_CAP_USD = self._orig_cap
        os.unlink(self._path)

    def _spend(self, account_id: str, amount: float, when: datetime) -> None:
        db.record_llm_cost_event(
            account_id=account_id,
            call_type="import",
            model="test-model",
            prompt_tokens=1,
            cached_tokens=0,
            completion_tokens=1,
            estimated_cost_usd=amount,
            created_at=_iso(when),
        )


class SpendCapUnitTests(_DBBase):
    def setUp(self) -> None:
        super().setUp()
        config.PER_ACCOUNT_30D_SPEND_CAP_USD = 5.0
        self.now = datetime(2026, 6, 15, 12, 0, tzinfo=timezone.utc)

    def test_under_cap_passes(self) -> None:
        self._spend("acct", 4.99, self.now)
        spendcap.check("acct", now=self.now)  # no raise

    def test_at_or_over_cap_raises(self) -> None:
        self._spend("acct", 3.0, self.now - timedelta(days=10))
        self._spend("acct", 2.5, self.now)  # total 5.5 >= 5.0 within window
        with self.assertRaises(spendcap.SpendCapExceeded) as ctx:
            spendcap.check("acct", now=self.now)
        self.assertEqual(ctx.exception.code, "spend_cap_reached")
        self.assertEqual(ctx.exception.limit, 5.0)

    def test_spend_older_than_30_days_ages_out(self) -> None:
        # Just outside the trailing window → must not count.
        self._spend("acct", 10.0, self.now - timedelta(days=31))
        self._spend("acct", 1.0, self.now)
        spendcap.check("acct", now=self.now)  # no raise

    def test_spend_inside_window_counts(self) -> None:
        # 29 days ago is inside the 30-day window → counts.
        self._spend("acct", 6.0, self.now - timedelta(days=29))
        with self.assertRaises(spendcap.SpendCapExceeded):
            spendcap.check("acct", now=self.now)

    def test_other_accounts_do_not_count(self) -> None:
        self._spend("other", 10.0, self.now)
        spendcap.check("acct", now=self.now)  # no raise

    def test_disabled_when_cap_not_positive(self) -> None:
        config.PER_ACCOUNT_30D_SPEND_CAP_USD = 0.0
        self._spend("acct", 100.0, self.now)
        spendcap.check("acct", now=self.now)  # disabled → no raise


class SpendCapEndpointTests(_DBBase):
    def setUp(self) -> None:
        super().setUp()
        from fastapi.testclient import TestClient
        from app.auth import security, service
        import app.main as main

        self._orig_key = config.APP_KEY
        config.APP_KEY = None  # fail-open: no X-App-Key needed here
        config.PER_ACCOUNT_30D_SPEND_CAP_USD = 5.0

        self.user = service.create_email_user("spend@example.com", "pw-123456", "Spend")
        self.token, _ = security.create_access_token(self.user.id)

        self.main = main
        self.create_calls = 0

        def _stub_create(url, uid, account_id=None):
            self.create_calls += 1
            raise AssertionError("create_job must not run once the spend cap is hit")

        self._orig_create = main.orchestrator.create_job
        self._orig_process = main.orchestrator.process_job
        main.orchestrator.create_job = _stub_create
        main.orchestrator.process_job = lambda job: None
        self.client = TestClient(main.app)

    def tearDown(self) -> None:
        config.APP_KEY = self._orig_key
        self.main.orchestrator.create_job = self._orig_create
        self.main.orchestrator.process_job = self._orig_process
        super().tearDown()

    def test_over_cap_returns_429_and_does_no_work(self) -> None:
        self._spend(self.user.id, 6.0, datetime.now(timezone.utc))
        r = self.client.post(
            "/v1/jobs",
            json={"url": "http://x"},
            headers={"Authorization": f"Bearer {self.token}"},
        )
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["detail"]["error_code"], "spend_cap_reached")
        self.assertEqual(self.create_calls, 0)


if __name__ == "__main__":
    unittest.main()
