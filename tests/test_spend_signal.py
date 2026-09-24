"""Soft spend-based circuit breaker (app/spendsignal.py + db.accounts_over_spend).

Advisory only, mirroring the device-multi-account signal: an account whose
trailing-window estimated LLM spend exceeds the threshold is FLAGGED for manual
review — never auto-blocked. Covers:
  * OVER / UNDER threshold — only accounts above the ceiling are flagged.
  * WINDOW — spend outside the trailing window doesn't count.
  * NULL bucket — unauthenticated (account_id NULL) spend is never flagged.
  * ADMIN — /admin/flagged-accounts surfaces spend flags alongside device flags,
    keeping the existing device keys, and is Basic-Auth gated.

    DATABASE_URL= python3 -m unittest tests.test_spend_signal
"""
from __future__ import annotations

import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from app import config, db, spendsignal


def _fresh_db() -> str:
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    return path


def _days_ago(n: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=n)).isoformat()


class _Base(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_db = config.DB_PATH
        self._orig_url = config.DATABASE_URL
        self._orig_thresh = config.SPEND_FLAG_THRESHOLD_USD
        self._orig_window = config.SPEND_FLAG_WINDOW_DAYS
        self._path = _fresh_db()
        config.DB_PATH = self._path
        config.DATABASE_URL = None
        config.SPEND_FLAG_THRESHOLD_USD = 100.0
        config.SPEND_FLAG_WINDOW_DAYS = 30
        db.init_db()

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        config.DATABASE_URL = self._orig_url
        config.SPEND_FLAG_THRESHOLD_USD = self._orig_thresh
        config.SPEND_FLAG_WINDOW_DAYS = self._orig_window
        os.unlink(self._path)

    def _spend(self, account_id, cost, when_iso, call_type="import"):
        db.record_llm_cost_event(
            account_id=account_id, call_type=call_type, model="gpt-5.4-mini",
            prompt_tokens=1000, cached_tokens=0, completion_tokens=1000,
            estimated_cost_usd=cost, created_at=when_iso,
        )


class SpendSignalTest(_Base):
    def test_over_threshold_is_flagged(self):
        # Two events summing to $120 inside the window → over the $100 ceiling.
        self._spend("whale", 80.0, _days_ago(2))
        self._spend("whale", 40.0, _days_ago(1))
        flagged = spendsignal.flagged_accounts()
        self.assertEqual(len(flagged), 1)
        self.assertEqual(flagged[0]["account_id"], "whale")
        self.assertAlmostEqual(flagged[0]["estimated_cost_usd"], 120.0, places=6)
        self.assertEqual(flagged[0]["calls"], 2)

    def test_at_or_under_threshold_not_flagged(self):
        self._spend("normal", 100.0, _days_ago(1))  # exactly at threshold → not over
        self._spend("light", 5.0, _days_ago(1))
        self.assertEqual(spendsignal.flagged_accounts(), [])

    def test_spend_outside_window_is_excluded(self):
        # $200 but 40 days ago → outside the 30-day window → not flagged.
        self._spend("dormant", 200.0, _days_ago(40))
        self.assertEqual(spendsignal.flagged_accounts(), [])

    def test_window_boundary_counts_recent_only(self):
        self._spend("mixed", 90.0, _days_ago(45))  # old, excluded
        self._spend("mixed", 60.0, _days_ago(3))   # recent
        self._spend("mixed", 60.0, _days_ago(1))   # recent → $120 in window
        flagged = spendsignal.flagged_accounts()
        self.assertEqual(len(flagged), 1)
        self.assertAlmostEqual(flagged[0]["estimated_cost_usd"], 120.0, places=6)

    def test_null_account_never_flagged(self):
        self._spend(None, 500.0, _days_ago(1))  # anonymous over-spend
        self.assertEqual(spendsignal.flagged_accounts(), [])

    def test_threshold_is_configurable(self):
        self._spend("acc", 50.0, _days_ago(1))
        self.assertEqual(spendsignal.flagged_accounts(), [])  # under $100
        config.SPEND_FLAG_THRESHOLD_USD = 40.0
        flagged = spendsignal.flagged_accounts()
        self.assertEqual(len(flagged), 1)
        self.assertEqual(flagged[0]["account_id"], "acc")


class AdminSurfaceTest(_Base):
    def setUp(self):
        super().setUp()
        self._orig_pw = config.ADMIN_PASSWORD
        self._orig_key = config.APP_KEY
        config.ADMIN_PASSWORD = "secret"
        config.APP_KEY = None
        from app.main import app
        self.client = TestClient(app)

    def tearDown(self):
        config.ADMIN_PASSWORD = self._orig_pw
        config.APP_KEY = self._orig_key
        super().tearDown()

    def test_requires_auth(self):
        self.assertEqual(self.client.get("/admin/flagged-accounts").status_code, 401)

    def test_spend_flags_appear_with_device_keys(self):
        self._spend("whale", 150.0, _days_ago(1))
        resp = self.client.get("/admin/flagged-accounts", auth=("admin", "secret"))
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        # Existing device-signal keys preserved.
        self.assertIn("count", body)
        self.assertIn("flagged", body)
        # New spend keys present and populated.
        self.assertEqual(body["spend_count"], 1)
        self.assertEqual(body["spend_flagged"][0]["account_id"], "whale")
        self.assertEqual(body["spend_threshold_usd"], 100.0)
        self.assertEqual(body["spend_window_days"], 30)


if __name__ == "__main__":
    unittest.main()
