"""Per-account LLM cost tracking (app/llm_cost.py + db + the wrapped call sites).

Covers:
  * PRICING MATH — estimated cost for mini/nano, cached-input discount, and the
    "unknown model" (null cost) case.
  * CHOKEPOINT — `pipeline.llm._raw_call` records one cost event per API call
    (including the corrective retry) against the active `track(...)` context, and
    records NOTHING when no context is active.
  * ATTRIBUTION — `orchestrator.process_job` establishes an "import" context so a
    model call made during extraction is attributed to the job's account; a cache
    hit (no LLM call) records nothing.
  * ADMIN QUERY / ENDPOINT — per-account sums group correctly (incl. the NULL
    unauthenticated bucket), honor the time window, and the /admin/llm-costs
    endpoint is Basic-Auth gated.

No network / no OpenAI key: the OpenAI client and the pipeline IO are stubbed.

    DATABASE_URL= python3 -m unittest tests.test_llm_cost
"""
from __future__ import annotations

import os
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

from fastapi.testclient import TestClient

from app import config, db, llm_cost
from app.models import DishIdentification, Job
from app.pipeline import llm, orchestrator
from app.pipeline.fetch import VideoMetadata
from app.pipeline.urls import ResolvedUrl


def _fresh_db() -> str:
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    return path


def _usage(prompt: int, completion: int, cached: int = 0):
    """A stand-in for OpenAI's CompletionUsage object."""
    return SimpleNamespace(
        prompt_tokens=prompt,
        completion_tokens=completion,
        prompt_tokens_details=SimpleNamespace(cached_tokens=cached),
    )


def _fake_completion(content: str, usage):
    message = SimpleNamespace(refusal=None, content=content)
    return SimpleNamespace(choices=[SimpleNamespace(message=message)], usage=usage)


class _DBBase(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_db = config.DB_PATH
        self._orig_url = config.DATABASE_URL
        self._path = _fresh_db()
        config.DB_PATH = self._path
        config.DATABASE_URL = None
        db.init_db()

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        config.DATABASE_URL = self._orig_url
        os.unlink(self._path)


class PricingMathTest(unittest.TestCase):
    def test_mini_rate_with_cached_discount(self):
        # 800 non-cached in @ $0.75/1M + 200 cached @ $0.075/1M + 500 out @ $4.50/1M
        cost = llm_cost.estimate_cost_usd("gpt-5.4-mini", 1000, 200, 500)
        self.assertAlmostEqual(cost, 0.0006 + 0.000015 + 0.00225, places=9)

    def test_nano_is_cheaper(self):
        mini = llm_cost.estimate_cost_usd("gpt-5.4-mini", 1000, 0, 1000)
        nano = llm_cost.estimate_cost_usd("gpt-5.4-nano", 1000, 0, 1000)
        self.assertLess(nano, mini)

    def test_unknown_model_returns_none(self):
        self.assertIsNone(llm_cost.estimate_cost_usd("gpt-does-not-exist", 100, 0, 100))

    def test_env_override(self):
        with mock.patch.dict(os.environ, {"LLM_PRICING_OVERRIDES": '{"gpt-x":[2.0,0.2,8.0]}'}):
            pricing = llm_cost._load_pricing()
        self.assertEqual(pricing["gpt-x"], (2.0, 0.2, 8.0))


class TrackAndRecordTest(_DBBase):
    def test_record_writes_row_within_context(self):
        with llm_cost.track("acc-1", "import"):
            llm_cost.record_usage("gpt-5.4-mini", _usage(1000, 500, cached=200))
        rows = db.sum_llm_cost_by_account()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["account_id"], "acc-1")
        self.assertEqual(rows[0]["calls"], 1)
        self.assertEqual(rows[0]["prompt_tokens"], 1000)
        self.assertEqual(rows[0]["cached_tokens"], 200)
        self.assertAlmostEqual(rows[0]["estimated_cost_usd"], 0.002865, places=9)

    def test_no_context_is_a_noop(self):
        llm_cost.record_usage("gpt-5.4-mini", _usage(1000, 500))
        self.assertEqual(db.sum_llm_cost_by_account(), [])

    def test_missing_usage_is_a_noop(self):
        with llm_cost.track("acc-1", "import"):
            llm_cost.record_usage("gpt-5.4-mini", None)
        self.assertEqual(db.sum_llm_cost_by_account(), [])

    def test_unknown_call_type_raises(self):
        with self.assertRaises(ValueError):
            with llm_cost.track("acc-1", "not-a-real-type"):
                pass

    def test_nested_context_restores_outer(self):
        with llm_cost.track("outer", "import"):
            with llm_cost.track("inner", "budget_plan"):
                llm_cost.record_usage("gpt-5.4-mini", _usage(10, 10))
            llm_cost.record_usage("gpt-5.4-mini", _usage(10, 10))
        rows = {r["account_id"]: r for r in db.sum_llm_cost_by_account()}
        self.assertEqual(set(rows), {"outer", "inner"})


class ChokepointTest(_DBBase):
    """`llm._raw_call` records against the active context (and the retry counts)."""

    _DISH_JSON = '{"dish_name":"Tomato Soup","cuisine":null,"confidence":0.9,"distinguishing_details":[]}'

    def test_raw_call_records_one_event(self):
        fake = mock.MagicMock()
        fake.chat.completions.parse.return_value = _fake_completion(self._DISH_JSON, _usage(300, 120))
        with mock.patch.object(llm, "_client", return_value=fake):
            with llm_cost.track("acc-1", "import"):
                dish = llm.identify_dish("some caption")
        self.assertEqual(dish.dish_name, "Tomato Soup")
        rows = db.sum_llm_cost_by_account()
        self.assertEqual(rows[0]["calls"], 1)
        self.assertEqual(rows[0]["prompt_tokens"], 300)

    def test_retry_records_two_events(self):
        # First response is invalid JSON → triggers the one corrective retry;
        # both API calls consume tokens and must both be recorded.
        fake = mock.MagicMock()
        fake.chat.completions.parse.side_effect = [
            _fake_completion("not json", _usage(300, 50)),
            _fake_completion(self._DISH_JSON, _usage(320, 60)),
        ]
        with mock.patch.object(llm, "_client", return_value=fake):
            with llm_cost.track("acc-1", "import"):
                llm.identify_dish("some caption")
        rows = db.sum_llm_cost_by_account()
        self.assertEqual(rows[0]["calls"], 2)
        self.assertEqual(rows[0]["prompt_tokens"], 620)


class OrchestratorAttributionTest(_DBBase):
    """process_job wraps extraction in an "import" context tied to the account."""

    VIDEO_ID = "instagram:ABC123"

    def _job(self, account_id):
        return Job(
            job_id="job-1",
            user_id="device-1",
            account_id=account_id,
            url="https://www.instagram.com/reel/ABC123/",
            created_at="2026-09-20T00:00:00+00:00",
        )

    def _run_fresh_import(self, account_id):
        resolved = ResolvedUrl(
            url="https://www.instagram.com/reel/ABC123/",
            platform="instagram",
            video_id="ABC123",
            canonical_video_id=self.VIDEO_ID,
        )
        meta = VideoMetadata(caption="cook it", thumbnail_url=None, video_id="ABC123", title="Dish")

        # Simulate what the real chokepoint does: an LLM call that records usage
        # against whatever context is active when it runs.
        def _extract(_caption):
            llm_cost.record_usage("gpt-5.4-mini", _usage(1200, 400))
            from app.models import Confidence, Ingredient, Instruction, LLMRecipe
            return LLMRecipe(
                title="Dish",
                ingredients=[Ingredient(name="thing")],
                instructions=[Instruction(step_number=1, text="do it")],
                confidence=Confidence(overall=0.9, ingredients_complete=True,
                                      instructions_complete=True, missing_fields=[]),
            )

        with mock.patch.object(orchestrator.urls, "resolve", return_value=resolved), \
             mock.patch.object(orchestrator.fetch, "fetch_instagram_metadata", return_value=meta), \
             mock.patch.object(orchestrator.signal, "has_recipe_signal", return_value=True), \
             mock.patch.object(orchestrator.llm, "extract_recipe", side_effect=_extract), \
             mock.patch.object(orchestrator.images, "resolve_image", return_value=(None, "none")):
            return orchestrator.process_job(self._job(account_id))

    def test_import_is_attributed_to_account(self):
        job = self._run_fresh_import("acc-42")
        self.assertEqual(job.status, "complete")
        rows = db.sum_llm_cost_by_account()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["account_id"], "acc-42")
        self.assertEqual(rows[0]["prompt_tokens"], 1200)

    def test_anonymous_import_records_null_account(self):
        self._run_fresh_import(None)
        rows = db.sum_llm_cost_by_account()
        self.assertEqual(len(rows), 1)
        self.assertIsNone(rows[0]["account_id"])

    def test_cache_hit_records_nothing(self):
        # Prime the cache, then a second import of the same video must be a pure
        # cache hit — no LLM call, no cost event.
        self._run_fresh_import("acc-42")
        before = db.sum_llm_cost_by_account()[0]["calls"]
        # Second run: same video id already cached → extract must NOT be called.
        resolved = ResolvedUrl(
            url="https://www.instagram.com/reel/ABC123/", platform="instagram",
            video_id="ABC123", canonical_video_id=self.VIDEO_ID,
        )
        meta = VideoMetadata(caption="cook it", thumbnail_url=None, video_id="ABC123", title="Dish")
        extract = mock.MagicMock()
        with mock.patch.object(orchestrator.urls, "resolve", return_value=resolved), \
             mock.patch.object(orchestrator.fetch, "fetch_instagram_metadata", return_value=meta), \
             mock.patch.object(orchestrator.signal, "has_recipe_signal", return_value=True), \
             mock.patch.object(orchestrator.llm, "extract_recipe", extract):
            orchestrator.process_job(
                Job(job_id="job-2", user_id="device-1", account_id="acc-42",
                    url="https://www.instagram.com/reel/ABC123/", created_at="2026-09-20T00:00:00+00:00")
            )
        extract.assert_not_called()
        self.assertEqual(db.sum_llm_cost_by_account()[0]["calls"], before)


class AdminQueryTest(_DBBase):
    def _seed(self):
        mk = lambda a, ct, cost, ts: db.record_llm_cost_event(
            account_id=a, call_type=ct, model="gpt-5.4-mini",
            prompt_tokens=100, cached_tokens=0, completion_tokens=50,
            estimated_cost_usd=cost, created_at=ts,
        )
        mk("acc-a", "import", 0.01, "2026-09-01T00:00:00+00:00")
        mk("acc-a", "budget_plan", 0.02, "2026-09-10T00:00:00+00:00")
        mk("acc-b", "import", 0.05, "2026-09-10T00:00:00+00:00")
        mk(None, "import", 0.03, "2026-09-10T00:00:00+00:00")

    def test_sum_groups_and_orders_by_cost(self):
        self._seed()
        rows = db.sum_llm_cost_by_account()
        # acc-b (0.05) > acc-a (0.03) > NULL (0.03)  — highest first
        self.assertEqual(rows[0]["account_id"], "acc-b")
        by = {r["account_id"]: r for r in rows}
        self.assertAlmostEqual(by["acc-a"]["estimated_cost_usd"], 0.03, places=6)
        self.assertEqual(by["acc-a"]["calls"], 2)
        self.assertIn(None, by)  # unauthenticated bucket present

    def test_window_filters(self):
        self._seed()
        rows = db.sum_llm_cost_by_account(since_iso="2026-09-05T00:00:00+00:00")
        by = {r["account_id"]: r for r in rows}
        # acc-a's 09-01 import is excluded; only its 09-10 budget_plan remains.
        self.assertAlmostEqual(by["acc-a"]["estimated_cost_usd"], 0.02, places=6)
        self.assertEqual(by["acc-a"]["calls"], 1)


class AdminEndpointTest(_DBBase):
    def setUp(self):
        super().setUp()
        self._orig_pw = config.ADMIN_PASSWORD
        self._orig_key = config.APP_KEY
        config.ADMIN_PASSWORD = "secret"
        config.APP_KEY = None  # keep the app-key gate open for the test
        from app.main import app
        self.client = TestClient(app)

    def tearDown(self):
        config.ADMIN_PASSWORD = self._orig_pw
        config.APP_KEY = self._orig_key
        super().tearDown()

    def test_requires_auth(self):
        self.assertEqual(self.client.get("/admin/llm-costs").status_code, 401)

    def test_returns_per_account_sum(self):
        db.record_llm_cost_event(
            account_id="acc-a", call_type="import", model="gpt-5.4-mini",
            prompt_tokens=100, cached_tokens=0, completion_tokens=50,
            estimated_cost_usd=0.04, created_at="2026-09-10T00:00:00+00:00",
        )
        resp = self.client.get("/admin/llm-costs", auth=("admin", "secret"))
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertEqual(body["account_count"], 1)
        self.assertAlmostEqual(body["total_estimated_cost_usd"], 0.04, places=6)
        self.assertEqual(body["accounts"][0]["account_id"], "acc-a")


if __name__ == "__main__":
    unittest.main()
