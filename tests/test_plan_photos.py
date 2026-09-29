"""Pexels stock photos on budget-plan meals (app/pipeline/photos.py + mealplan wiring).
Pexels is always mocked — no test touches the network.

    DATABASE_URL= .venv/bin/python -m pytest tests/test_plan_photos.py
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from unittest import mock

import requests

from app import config, db
from app.pipeline import photos
from tests.test_budget_planner import OVEN, _Base, meal


def _pexels_payload(n: int = 1) -> dict:
    return {
        "photos": [
            {
                "url": f"https://www.pexels.com/photo/{n}/",
                "photographer": f"Ana {n}",
                "photographer_url": f"https://www.pexels.com/@ana{n}",
                "src": {"large": f"https://images.pexels.com/{n}-large.jpg", "original": "x"},
            }
        ]
    }


class _Resp:
    def __init__(self, payload: dict, status: int = 200):
        self._payload, self.status_code = payload, status

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise requests.HTTPError(str(self.status_code))

    def json(self) -> dict:
        return self._payload


def _fake_get(url, params=None, headers=None, timeout=None):
    # Distinct photo per query so tests can tell them apart.
    return _Resp(_pexels_payload(abs(hash(params["query"])) % 1000))


class _PhotoBase(_Base):
    def setUp(self) -> None:
        super().setUp()
        self._key = config.PEXELS_API_KEY
        self._cap = config.PEXELS_MAX_CALLS_PER_HOUR
        config.PEXELS_API_KEY = "test-key"
        config.PEXELS_MAX_CALLS_PER_HOUR = 150
        photos.reset_rate_counter()

    def tearDown(self) -> None:
        config.PEXELS_API_KEY = self._key
        config.PEXELS_MAX_CALLS_PER_HOUR = self._cap
        photos.reset_rate_counter()
        super().tearDown()

    def three(self):
        return [
            meal("A", 30, [OVEN]).model_copy(update={"photo_query": "chicken burrito bowl"}),
            meal("B", 30, [OVEN]).model_copy(update={"photo_query": "lentil soup"}),
            meal("C", 30, [OVEN]),  # no photo_query → falls back to the title
        ]

    def make_plan(self, get=_fake_get):
        with mock.patch("app.pipeline.photos.requests.get", side_effect=get) as g:
            r = self.plan(gen_return=self.three())
        self.assertEqual(r.status_code, 200, r.text)
        return r.json(), g


class PhotoAttachTests(_PhotoBase):
    def test_photo_attached_on_the_recipe_object(self) -> None:
        data, g = self.make_plan()
        self.assertEqual(g.call_count, 3)
        recipe = data["recipes"][0]["recipe"]
        self.assertTrue(recipe["image_url"].startswith("https://images.pexels.com/"))
        self.assertEqual(recipe["image_source"], "stock_photo")
        self.assertEqual(set(recipe["photo_credit"]), {"photographer", "photographer_url", "pexels_url"})
        self.assertNotIn("image_url", data["recipes"][0])  # not a meal-level sibling

    def test_request_shape_and_fallback_to_title(self) -> None:
        _, g = self.make_plan()
        queries = sorted(c.kwargs["params"]["query"] for c in g.call_args_list)
        self.assertEqual(queries, ["c", "chicken burrito bowl", "lentil soup"])
        kw = g.call_args.kwargs
        self.assertEqual(kw["headers"], {"Authorization": "test-key"})
        self.assertEqual(kw["timeout"], 3)
        for c in g.call_args_list:
            p = c.kwargs["params"]
            self.assertEqual((p["per_page"], p["orientation"], p["size"]), (5, "landscape", "medium"))

    def test_persisted_recipe_and_ledger_carry_the_photo(self) -> None:
        data, _ = self.make_plan()
        rid = data["recipes"][0]["recipe"]["recipe_id"]
        saved = db.get_recipe(rid)
        self.assertEqual(saved.image_url, data["recipes"][0]["recipe"]["image_url"])
        self.assertEqual(saved.image_source, "stock_photo")
        self.assertEqual(saved.photo_credit.photographer, data["recipes"][0]["recipe"]["photo_credit"]["photographer"])
        ledger = json.loads(db.get_budget_plan(data["plan_id"])["plan_json"])
        self.assertEqual(ledger[0]["image_url"], saved.image_url)
        self.assertEqual(ledger[0]["photo_credit"]["pexels_url"], saved.photo_credit.pexels_url)

    def test_swap_gets_a_photo(self) -> None:
        data, _ = self.make_plan()
        repl = meal("Z", 30, [OVEN]).model_copy(update={"photo_query": "baked ziti"})
        with mock.patch("app.pipeline.photos.requests.get", side_effect=_fake_get), \
             mock.patch("app.mealplan.llm.generate_single_meal", return_value=repl):
            r = self.swap(data["plan_id"], 1)
        self.assertEqual(r.status_code, 200, r.text)
        recipe = r.json()["meal"]["recipe"]
        self.assertTrue(recipe["image_url"])
        self.assertEqual(recipe["image_source"], "stock_photo")
        self.assertTrue(recipe["photo_credit"]["photographer"])
        ledger = json.loads(db.get_budget_plan(data["plan_id"])["plan_json"])
        self.assertEqual(ledger[1]["image_url"], recipe["image_url"])


class PhotoFailureTests(_PhotoBase):
    def test_timeout_means_no_photo_and_the_plan_still_succeeds(self) -> None:
        def boom(*a, **k):
            raise requests.Timeout("slow")

        data, _ = self.make_plan(get=boom)
        self.assertEqual(len(data["recipes"]), 3)
        for item in data["recipes"]:
            self.assertIsNone(item["recipe"]["image_url"])
            self.assertEqual(item["recipe"]["image_source"], "none")
            self.assertIsNone(item["recipe"]["photo_credit"])

    def test_http_error_and_empty_results_are_no_photo(self) -> None:
        data, _ = self.make_plan(get=lambda *a, **k: _Resp({}, 500))
        self.assertIsNone(data["recipes"][0]["recipe"]["image_url"])
        data, _ = self.make_plan(get=lambda *a, **k: _Resp({"photos": []}))
        self.assertIsNone(data["recipes"][0]["recipe"]["image_url"])

    def test_no_key_is_a_noop(self) -> None:
        config.PEXELS_API_KEY = None
        data, g = self.make_plan()
        g.assert_not_called()
        self.assertIsNone(data["recipes"][0]["recipe"]["image_url"])

    def test_hourly_cap_returns_none_without_calling(self) -> None:
        config.PEXELS_MAX_CALLS_PER_HOUR = 1
        self.assertIsNotNone(self._search("first dish"))
        with mock.patch("app.pipeline.photos.requests.get", side_effect=_fake_get) as g:
            self.assertIsNone(photos.search_dish_photo("second dish"))
        g.assert_not_called()

    def _search(self, q):
        with mock.patch("app.pipeline.photos.requests.get", side_effect=_fake_get):
            return photos.search_dish_photo(q)


class PhotoCacheTests(_PhotoBase):
    def test_cache_hit_makes_no_call(self) -> None:
        _, first = self.make_plan()
        self.assertEqual(first.call_count, 3)
        with mock.patch("app.pipeline.photos.requests.get", side_effect=_fake_get) as g:
            r = self.plan(gen_return=self.three())
        self.assertEqual(r.status_code, 200)
        g.assert_not_called()
        self.assertTrue(r.json()["recipes"][0]["recipe"]["image_url"])

    def test_query_is_normalized_for_the_cache(self) -> None:
        with mock.patch("app.pipeline.photos.requests.get", side_effect=_fake_get) as g:
            a = photos.search_dish_photo("Lentil  Soup ")
            b = photos.search_dish_photo("lentil soup")
        self.assertEqual(g.call_count, 1)
        self.assertEqual(a, b)

    def test_negative_result_is_cached_then_expires_after_seven_days(self) -> None:
        empty = lambda *a, **k: _Resp({"photos": []})  # noqa: E731
        with mock.patch("app.pipeline.photos.requests.get", side_effect=empty) as g:
            self.assertIsNone(photos.search_dish_photo("mystery dish"))
            self.assertIsNone(photos.search_dish_photo("mystery dish"))
        self.assertEqual(g.call_count, 1)  # negative hit served from cache
        old = (datetime.now(timezone.utc) - timedelta(days=8)).isoformat()
        db.save_photo_cache("mystery dish", photos.NONE_MARKER, old)
        with mock.patch("app.pipeline.photos.requests.get", side_effect=_fake_get) as g:
            self.assertIsNotNone(photos.search_dish_photo("mystery dish"))
        self.assertEqual(g.call_count, 1)  # expired → looked up again

    def test_fresh_negative_within_seven_days_is_still_a_hit(self) -> None:
        recent = (datetime.now(timezone.utc) - timedelta(days=6)).isoformat()
        db.save_photo_cache("mystery dish", photos.NONE_MARKER, recent)
        with mock.patch("app.pipeline.photos.requests.get", side_effect=_fake_get) as g:
            self.assertIsNone(photos.search_dish_photo("mystery dish"))
        g.assert_not_called()


class HealthPhotosTests(_PhotoBase):
    def test_health_reports_configured_and_missing_never_the_key(self) -> None:
        r = self.client.get("/health")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["photos"], "configured")
        self.assertNotIn("test-key", r.text)
        config.PEXELS_API_KEY = None
        self.assertEqual(self.client.get("/health").json()["photos"], "missing")
