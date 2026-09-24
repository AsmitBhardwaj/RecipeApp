"""Free-tier monthly import limit (app/importlimit.py + the /v1/jobs enforcement
in app/main.py). Covers the four rules from the spec:

  * COUNTING — only successful imports count; cache hits count; failed /
    site_blocked jobs do not; a paste-text retry of the same job is not counted
    twice (idempotent per job_id).
  * GRANDFATHER — accounts created before FREE_LIMIT_EFFECTIVE_DATE are exempt.
  * PRO BYPASS — a Pro account (client claim) is never limited.
  * LIMIT-REACHED ERROR PATH — the policy raises a coded exception and the
    endpoint returns HTTP 402 with the distinct `free_limit_reached` code.

Everything runs against a throwaway SQLite file; the endpoint tests stub the
orchestrator so no real pipeline/LLM runs.

    DATABASE_URL= python3 -m unittest tests.test_import_limit
"""
from __future__ import annotations

import os
import tempfile
import unittest
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from app import config, db, importlimit
from app.models import Job, Recipe, Servings
from app.pipeline import orchestrator


def _fresh_db() -> str:
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    return path


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _this_month() -> str:
    return importlimit.month_key(datetime.now(timezone.utc))


@dataclass
class _FakeAccount:
    id: str
    created_at: Optional[str]


def _recipe(video_id: str = "instagram:v1") -> Recipe:
    return Recipe(
        recipe_id="r-" + video_id,
        canonical_video_id=video_id,
        title="Test dish",
        servings=Servings(),
        source_type="caption",
        image_source="none",
    )


def _job(job_id: str, account_id: Optional[str]) -> Job:
    return Job(
        job_id=job_id,
        user_id="device-x",
        account_id=account_id,
        url="https://example.com/r",
        canonical_video_id="instagram:v1",
        platform="instagram",
        created_at=_now_iso(),
    )


class _DBTestBase(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_db = config.DB_PATH
        self._orig_url = config.DATABASE_URL
        self._orig_limit = config.FREE_IMPORT_LIMIT
        self._orig_effective = config.FREE_LIMIT_EFFECTIVE_DATE
        self._path = _fresh_db()
        config.DB_PATH = self._path
        config.DATABASE_URL = None  # force the local sqlite path
        db.init_db()

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        config.DATABASE_URL = self._orig_url
        config.FREE_IMPORT_LIMIT = self._orig_limit
        config.FREE_LIMIT_EFFECTIVE_DATE = self._orig_effective
        os.unlink(self._path)


class CountingRulesTests(_DBTestBase):
    """Exercises the real orchestrator chokepoints (_finalize / _fail) so the
    counting semantics are tested where they actually live."""

    def test_successful_import_counts_once(self) -> None:
        orchestrator._finalize(_job("j1", "acct-A"), _recipe())
        self.assertEqual(db.count_imports_in_month("acct-A", _this_month()), 1)

    def test_cache_hit_counts(self) -> None:
        # A cache hit funnels through the same _finalize, so it counts — an import
        # is an import even when no LLM ran.
        cached = _recipe()
        db.save_recipe(cached)
        orchestrator._finalize(_job("j-cache", "acct-A"), cached)
        self.assertEqual(db.count_imports_in_month("acct-A", _this_month()), 1)

    def test_failed_and_site_blocked_do_not_count(self) -> None:
        orchestrator._fail(_job("j-fail", "acct-A"), "no_recipe_found", "nope")
        orchestrator._fail(_job("j-block", "acct-A"), "site_blocked", "blocked")
        self.assertEqual(db.count_imports_in_month("acct-A", _this_month()), 0)

    def test_paste_retry_of_same_job_not_counted_twice(self) -> None:
        # A paste retry reuses the SAME job_id: it fails, then the paste finalizes
        # it. Recording is idempotent per job_id, so the total is 1, not 2.
        job = _job("j-retry", "acct-A")
        orchestrator._fail(job, "site_blocked", "blocked")
        self.assertEqual(db.count_imports_in_month("acct-A", _this_month()), 0)
        orchestrator._finalize(job, _recipe())  # same job_id succeeds on paste
        orchestrator._finalize(job, _recipe())  # defensive: re-finalize is a no-op
        self.assertEqual(db.count_imports_in_month("acct-A", _this_month()), 1)

    def test_anonymous_import_is_not_recorded(self) -> None:
        # No account => nothing to count against (enforcement is account-scoped).
        orchestrator._finalize(_job("j-anon", None), _recipe())
        self.assertEqual(db.count_imports_in_month("device-x", _this_month()), 0)

    def test_counts_are_per_account_and_per_month(self) -> None:
        orchestrator._finalize(_job("a1", "acct-A"), _recipe())
        orchestrator._finalize(_job("b1", "acct-B"), _recipe())
        self.assertEqual(db.count_imports_in_month("acct-A", _this_month()), 1)
        self.assertEqual(db.count_imports_in_month("acct-B", _this_month()), 1)
        # A different month bucket is empty.
        self.assertEqual(db.count_imports_in_month("acct-A", "2000-01"), 0)


class PolicyTests(_DBTestBase):
    def setUp(self) -> None:
        super().setUp()
        config.FREE_IMPORT_LIMIT = 2
        # Effective date in the PAST so a "now"-created account is NOT grandfathered.
        config.FREE_LIMIT_EFFECTIVE_DATE = "2000-01-01T00:00:00+00:00"
        self.account = _FakeAccount(id="acct-A", created_at=_now_iso())

    def _seed(self, n: int) -> None:
        for i in range(n):
            db.record_import_event("acct-A", f"seed-{i}", _this_month(), _now_iso())

    def test_under_limit_is_allowed(self) -> None:
        self._seed(1)  # 1 < 2
        importlimit.check_allowed(self.account, is_pro=False)  # no raise

    def test_at_limit_raises_with_code(self) -> None:
        self._seed(2)  # 2 >= 2
        with self.assertRaises(importlimit.ImportLimitExceeded) as ctx:
            importlimit.check_allowed(self.account, is_pro=False)
        self.assertEqual(ctx.exception.code, "free_limit_reached")
        self.assertEqual(ctx.exception.limit, 2)

    def test_pro_is_never_limited(self) -> None:
        self._seed(5)  # well over the limit
        importlimit.check_allowed(self.account, is_pro=True)  # no raise

    def test_grandfathered_account_is_exempt(self) -> None:
        self._seed(5)
        # Effective date AFTER this account's creation => grandfathered forever.
        config.FREE_LIMIT_EFFECTIVE_DATE = "2099-01-01T00:00:00+00:00"
        importlimit.check_allowed(self.account, is_pro=False)  # no raise

    def test_account_created_after_effective_date_is_limited(self) -> None:
        self._seed(2)
        config.FREE_LIMIT_EFFECTIVE_DATE = "2020-01-01T00:00:00+00:00"
        newer = _FakeAccount(id="acct-A", created_at="2020-06-01T00:00:00+00:00")
        with self.assertRaises(importlimit.ImportLimitExceeded):
            importlimit.check_allowed(newer, is_pro=False)

    def test_anonymous_is_never_limited(self) -> None:
        self._seed(5)
        importlimit.check_allowed(None, is_pro=False)  # no raise


class EndpointEnforcementTests(_DBTestBase):
    """Full request path: a real user + JWT hits /v1/jobs and gets 402 with the
    distinct code when over the cap; Pro and grandfathered callers pass."""

    def setUp(self) -> None:
        super().setUp()
        from fastapi.testclient import TestClient
        from app.auth import security, service
        import app.main as main

        self._orig_key = config.APP_KEY
        config.APP_KEY = None  # fail-open: no X-App-Key needed for these tests
        config.FREE_IMPORT_LIMIT = 2
        config.FREE_LIMIT_EFFECTIVE_DATE = "2000-01-01T00:00:00+00:00"  # not grandfathered

        self.user = service.create_email_user("cap@example.com", "pw-123456", "Cap")
        self.token, _ = security.create_access_token(self.user.id)

        # Stub the pipeline so an allowed submit does no real work, and restore in
        # tearDown so we don't pollute other modules' view of the orchestrator.
        self.main = main
        self._orig_create = main.orchestrator.create_job
        self._orig_process = main.orchestrator.process_job
        main.orchestrator.create_job = lambda url, uid, account_id=None: _job("stub", account_id)
        main.orchestrator.process_job = lambda job: None
        self.client = TestClient(main.app)

    def tearDown(self) -> None:
        config.APP_KEY = self._orig_key
        self.main.orchestrator.create_job = self._orig_create
        self.main.orchestrator.process_job = self._orig_process
        super().tearDown()

    def _seed(self, n: int) -> None:
        for i in range(n):
            db.record_import_event(self.user.id, f"seed-{i}", _this_month(), _now_iso())

    def _headers(self, pro: bool = False) -> dict:
        h = {"Authorization": f"Bearer {self.token}", "X-User-Id": "device-1"}
        if pro:
            h["X-Pro-Entitled"] = "1"
        return h

    def test_usage_endpoint_returns_exact_remaining_count(self) -> None:
        self._seed(1)
        r = self.client.get("/v1/import-usage", headers=self._headers())
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertEqual(body["limit"], 2)
        self.assertEqual(body["used"], 1)
        self.assertEqual(body["remaining"], 1)
        self.assertTrue(body["is_limited"])
        self.assertIn("resets_at", body)

    def test_usage_endpoint_requires_authentication(self) -> None:
        r = self.client.get("/v1/import-usage")
        self.assertEqual(r.status_code, 401)

    def test_under_limit_returns_200(self) -> None:
        self._seed(1)
        r = self.client.post("/v1/jobs", json={"url": "http://x"}, headers=self._headers())
        self.assertEqual(r.status_code, 200)

    def test_over_limit_returns_402_with_code(self) -> None:
        self._seed(2)
        r = self.client.post("/v1/jobs", json={"url": "http://x"}, headers=self._headers())
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["detail"]["error_code"], "free_limit_reached")

    def test_pro_claim_bypasses_limit(self) -> None:
        self._seed(5)
        r = self.client.post("/v1/jobs", json={"url": "http://x"}, headers=self._headers(pro=True))
        self.assertEqual(r.status_code, 200)

    def test_grandfathered_account_bypasses_limit(self) -> None:
        self._seed(5)
        config.FREE_LIMIT_EFFECTIVE_DATE = "2099-01-01T00:00:00+00:00"
        r = self.client.post("/v1/jobs", json={"url": "http://x"}, headers=self._headers())
        self.assertEqual(r.status_code, 200)

    def test_anonymous_over_seeded_count_is_not_limited(self) -> None:
        # No token => no account => the per-account cap does not apply.
        self._seed(5)
        r = self.client.post("/v1/jobs", json={"url": "http://x"}, headers={"X-User-Id": "device-1"})
        self.assertEqual(r.status_code, 200)

    def test_paste_endpoint_enforces_limit(self) -> None:
        self._seed(2)
        # job_id doesn't matter — the 402 is raised before the job is loaded.
        r = self.client.post(
            "/v1/jobs/any/paste", json={"text": "x" * 40}, headers=self._headers()
        )
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["detail"]["error_code"], "free_limit_reached")


if __name__ == "__main__":
    unittest.main()
