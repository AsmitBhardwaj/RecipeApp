"""Plan on a Budget: per-person budget floor (app/budget.py), the regional cost
multiplier (app/pipeline/regional_cost.py), and the endpoint's gating + floor
enforcement (app/mealplan.py).

    DATABASE_URL= python3 -m unittest tests.test_budget_plan
"""
from __future__ import annotations

import os
import tempfile
import unittest
from unittest import mock

from fastapi.testclient import TestClient

from app import budget, config, db
from app.models import CostEstimate, LLMRecipe
from app.pipeline import regional_cost
from app.pipeline.llm import BudgetPlanRecipeLLM


def _fresh_db() -> str:
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    return path


class BudgetMathTests(unittest.TestCase):
    """The derived budget model: min/max bounds and count/richness decisions all
    come from the per-person per-dinner anchors. Anchors are pinned here so an env
    override can't shift the expected numbers."""

    def setUp(self) -> None:
        self._orig = (
            budget.PER_DINNER_FLOOR, budget.PER_DINNER_COMFORTABLE,
            budget.PER_DINNER_RICHNESS_CEILING, budget.MIN_RECIPE_COUNT,
            config.BUDGET_PLAN_RECIPE_COUNT,
        )
        budget.PER_DINNER_FLOOR = 3.0
        budget.PER_DINNER_COMFORTABLE = 8.0
        budget.PER_DINNER_RICHNESS_CEILING = 12.0
        budget.MIN_RECIPE_COUNT = 4
        config.BUDGET_PLAN_RECIPE_COUNT = 7

    def tearDown(self) -> None:
        (budget.PER_DINNER_FLOOR, budget.PER_DINNER_COMFORTABLE,
         budget.PER_DINNER_RICHNESS_CEILING, budget.MIN_RECIPE_COUNT,
         config.BUDGET_PLAN_RECIPE_COUNT) = self._orig

    def test_min_budget_is_floor_times_min_count_per_person(self) -> None:
        # 3 × 4 × P, rounded to $5.
        self.assertEqual(budget.min_budget(1), 10)   # 12 -> 10
        self.assertEqual(budget.min_budget(2), 25)   # 24 -> 25
        self.assertEqual(budget.min_budget(4), 50)   # 48 -> 50

    def test_max_budget_is_ceiling_times_max_count_per_person(self) -> None:
        # 12 × 7 × P, rounded to $5.
        self.assertEqual(budget.max_budget(1), 85)   # 84 -> 85
        self.assertEqual(budget.max_budget(2), 170)  # 168 -> 170
        self.assertEqual(budget.max_budget(4), 335)  # 336 -> 335

    def test_min_below_max_and_household_scales(self) -> None:
        self.assertLess(budget.min_budget(2), budget.max_budget(2))
        self.assertGreater(budget.min_budget(4), budget.min_budget(2))
        self.assertGreater(budget.max_budget(4), budget.max_budget(2))

    def test_household_clamped_to_at_least_one(self) -> None:
        self.assertEqual(budget.min_budget(0), budget.min_budget(1))
        self.assertEqual(budget.max_budget(-3), budget.max_budget(1))

    def test_target_recipe_count_full_week_when_budget_ample(self) -> None:
        # $200 for 2 → $14/dinner/person ≥ floor → full 7.
        self.assertEqual(budget.target_recipe_count(200, 2), 7)
        # At exactly floor ($3/dinner/person = $42 for 2 over 7) → still 7.
        self.assertEqual(budget.target_recipe_count(42, 2), 7)

    def test_target_recipe_count_reduced_when_budget_thin(self) -> None:
        # $30 for 2 → $2.14/dinner at 7 (< floor) → cut to floor(30/6)=5.
        self.assertEqual(budget.target_recipe_count(30, 2), 5)
        # At the min ($24 for 2) → 4 (the ⌊⌋ floor count).
        self.assertEqual(budget.target_recipe_count(24, 2), 4)
        # Never below min_recipe_count even for a tiny 1-person budget.
        self.assertEqual(budget.target_recipe_count(12, 1), 4)

    def test_wants_rich_only_above_comfortable(self) -> None:
        self.assertTrue(budget.wants_rich(200, 2))    # $14/dinner > $8
        self.assertFalse(budget.wants_rich(42, 2))    # $3/dinner
        self.assertFalse(budget.wants_rich(112, 2))   # exactly $8/dinner, not >
        self.assertTrue(budget.wants_rich(120, 2))    # $8.57/dinner > $8


class RegionalMultiplierTests(unittest.TestCase):
    def test_country_baseline_and_area_modifier_combine(self) -> None:
        # US (1.00) × city (1.15) = 1.15; GB (1.10) × rural (0.85) = 0.935 → 0.94.
        self.assertEqual(regional_cost.multiplier_for("US", "city"), 1.15)
        self.assertEqual(regional_cost.multiplier_for("GB", "rural"), 0.94)
        self.assertEqual(regional_cost.multiplier_for("US", "suburb"), 1.0)

    def test_unknown_country_falls_back_to_default_baseline(self) -> None:
        # Unmapped country → 1.0 baseline; suburb is the 1.0 area anchor.
        self.assertEqual(regional_cost.multiplier_for("ZZ", "suburb"), regional_cost.DEFAULT_BASELINE)

    def test_missing_parts_fall_back_to_defaults(self) -> None:
        self.assertEqual(regional_cost.multiplier_for(None, None), 1.0)
        self.assertEqual(regional_cost.multiplier_for("", ""), 1.0)
        # One part set, the other missing → the set part still applies.
        self.assertEqual(regional_cost.multiplier_for("IN", None), regional_cost.COUNTRY_BASELINES["IN"])
        self.assertEqual(regional_cost.multiplier_for(None, "city"), regional_cost.AREA_MODIFIERS["city"])

    def test_country_is_case_insensitive(self) -> None:
        self.assertEqual(regional_cost.multiplier_for("gb", "city"), regional_cost.multiplier_for("GB", "city"))

    def test_area_type_is_case_insensitive(self) -> None:
        self.assertEqual(regional_cost.multiplier_for("US", "CITY"), regional_cost.multiplier_for("US", "city"))

    def test_ordering_is_sane(self) -> None:
        # High-cost country/city > US suburb baseline > low-cost country/rural.
        self.assertGreater(
            regional_cost.multiplier_for("CH", "city"), regional_cost.multiplier_for("US", "suburb")
        )
        self.assertGreater(
            regional_cost.multiplier_for("US", "suburb"), regional_cost.multiplier_for("IN", "rural")
        )
        # Within one country, city > suburb > rural.
        self.assertGreater(regional_cost.multiplier_for("US", "city"), regional_cost.multiplier_for("US", "suburb"))
        self.assertGreater(regional_cost.multiplier_for("US", "suburb"), regional_cost.multiplier_for("US", "rural"))


class MultiplierTableTests(unittest.TestCase):
    """The flat (country, area_type) table must stay internally consistent."""

    def test_suburb_is_the_area_anchor(self) -> None:
        self.assertEqual(regional_cost.AREA_MODIFIERS["suburb"], 1.0)
        self.assertGreater(regional_cost.AREA_MODIFIERS["city"], 1.0)
        self.assertLess(regional_cost.AREA_MODIFIERS["rural"], 1.0)

    def test_us_baseline_is_the_national_anchor(self) -> None:
        self.assertEqual(regional_cost.COUNTRY_BASELINES["US"], 1.0)

    def test_area_keys_match_the_ios_enum_values(self) -> None:
        # RecipeKit.AreaType raw values must stay in sync with these keys.
        self.assertEqual(set(regional_cost.AREA_MODIFIERS), {"city", "suburb", "rural"})


class BudgetPlanEndpointTests(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_db = config.DB_PATH
        self._orig_url = config.DATABASE_URL
        self._orig_key = config.APP_KEY
        # Pin the budget anchors so an env override can't move the bounds/counts.
        self._orig_anchors = (
            budget.PER_DINNER_FLOOR, budget.PER_DINNER_COMFORTABLE,
            budget.PER_DINNER_RICHNESS_CEILING, budget.MIN_RECIPE_COUNT,
            config.BUDGET_PLAN_RECIPE_COUNT,
        )
        budget.PER_DINNER_FLOOR = 3.0
        budget.PER_DINNER_COMFORTABLE = 8.0
        budget.PER_DINNER_RICHNESS_CEILING = 12.0
        budget.MIN_RECIPE_COUNT = 4
        config.BUDGET_PLAN_RECIPE_COUNT = 7
        self._path = _fresh_db()
        config.DB_PATH = self._path
        config.DATABASE_URL = None
        config.APP_KEY = None  # fail-open: no X-App-Key needed
        db.init_db()

        from app.auth import security, service
        import app.main as main

        self.user = service.create_email_user("plan@example.com", "pw-123456", "Plan")
        self.token, _ = security.create_access_token(self.user.id)
        self.main = main
        self.client = TestClient(main.app)

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        config.DATABASE_URL = self._orig_url
        config.APP_KEY = self._orig_key
        (budget.PER_DINNER_FLOOR, budget.PER_DINNER_COMFORTABLE,
         budget.PER_DINNER_RICHNESS_CEILING, budget.MIN_RECIPE_COUNT,
         config.BUDGET_PLAN_RECIPE_COUNT) = self._orig_anchors
        os.unlink(self._path)

    def _headers(self, pro: bool = True) -> dict:
        h = {"Authorization": f"Bearer {self.token}", "X-User-Id": "device-1"}
        if pro:
            h["X-Pro-Entitled"] = "1"
        return h

    def _body(self, **over) -> dict:
        body = {
            "budget": 100,
            "currency": "USD",
            "household_size": 2,
            "dietary_preferences": [],
            "pantry_items": ["rice", "eggs"],
            "country": "US",
            "area_type": "city",
        }
        body.update(over)
        return body

    def _fake_recipes(self):
        return [
            BudgetPlanRecipeLLM(
                recipe=LLMRecipe(title="Fried Rice", ingredients=[], instructions=[]),
                baseline_cost=CostEstimate(amount=10.0, currency="USD", basis="llm-v1"),
                health_signal="Veg-forward",
            )
        ]

    def _plan(self, *amounts, title="Recipe", health="Veg-forward"):
        """A fake generated plan: one recipe per baseline amount (US-baseline USD)."""
        return [
            BudgetPlanRecipeLLM(
                recipe=LLMRecipe(title=f"{title}-{i}", ingredients=[], instructions=[]),
                baseline_cost=CostEstimate(amount=float(a), currency="USD", basis="llm-v1"),
                health_signal=health,
            )
            for i, a in enumerate(amounts)
        ]

    def test_free_user_cannot_call_endpoint(self) -> None:
        # No X-Pro-Entitled → 403 pro_required, before any generation.
        r = self.client.post("/v1/meal-plan/budget", json=self._body(), headers=self._headers(pro=False))
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["detail"]["error_code"], "pro_required")

    def test_below_minimum_is_rejected_even_if_client_missed_it(self) -> None:
        # household 4 → min $50 (3×4×4=48 → $50); a client that sent $40 anyway is
        # rejected server-side, before any LLM spend.
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=self._fake_recipes()) as gen:
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self._body(budget=40, household_size=4, area_type="suburb"),
                headers=self._headers(),
            )
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["detail"]["error_code"], "budget_below_minimum")
        self.assertEqual(r.json()["detail"]["min_budget"], 50)
        gen.assert_not_called()  # rejected before spending on generation

    def test_above_maximum_is_rejected(self) -> None:
        # household 2 → max $170 (12×7×2=168 → $170); $200 is rejected, no LLM spend.
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=self._plan(90.0)) as gen:
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self._body(budget=200, area_type="suburb"),
                headers=self._headers(),
            )
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["detail"]["error_code"], "budget_above_maximum")
        self.assertEqual(r.json()["detail"]["max_budget"], 170)
        gen.assert_not_called()

    def test_low_budget_reduces_recipe_count(self) -> None:
        # $30 for 2 (suburb) → $2.14/dinner at 7 (< $3 floor) → request only 5.
        with mock.patch(
            "app.mealplan.llm.generate_budget_plan", return_value=self._plan(9.0, 9.0, 9.0)
        ) as gen:
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self._body(budget=30, area_type="suburb"),
                headers=self._headers(),
            )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_args.kwargs["count"], 5)   # cut from 7
        self.assertFalse(gen.call_args.kwargs["rich"])       # thin budget: not rich

    def test_high_budget_steers_rich_without_increasing_count(self) -> None:
        # $150 for 2 (suburb) → $10.7/dinner (> $8 comfortable) → 7 dinners, richer.
        with mock.patch(
            "app.mealplan.llm.generate_budget_plan", return_value=self._plan(130.0)
        ) as gen:
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self._body(budget=150, area_type="suburb"),
                headers=self._headers(),
            )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_args.kwargs["count"], 7)   # NOT increased beyond a week
        self.assertTrue(gen.call_args.kwargs["rich"])        # extra budget → richness

    def test_happy_path_within_band_no_retry_saves_recipe(self) -> None:
        # US/suburb → 1.0 multiplier; budget 100 → band [85, 100]. A $90 plan is
        # inside the band, so it ships as-is with NO corrective retry.
        with mock.patch(
            "app.mealplan.llm.generate_budget_plan", return_value=self._plan(90.0)
        ) as gen:
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self._body(area_type="suburb"),
                headers=self._headers(),
            )
        self.assertEqual(r.status_code, 200, r.text)
        data = r.json()
        self.assertEqual(data["regional_multiplier"], 1.0)
        self.assertEqual(gen.call_count, 1)  # within band → no retry
        self.assertEqual(len(data["recipes"]), 1)
        planned = data["recipes"][0]
        self.assertAlmostEqual(planned["estimated_cost"]["amount"], 90.0, places=2)
        self.assertEqual(planned["health_signal"], "Veg-forward")
        # Recipe was written to the shared cache under its synthetic key.
        self.assertIsNotNone(db.get_recipe(planned["recipe"]["recipe_id"]))

    def test_unknown_location_uses_default_multiplier(self) -> None:
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=self._plan(90.0)):
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self._body(country="ZZ", area_type="spacestation"),
                headers=self._headers(),
            )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["regional_multiplier"], 1.0)

    def test_budget_is_converted_to_baseline_space_before_generation(self) -> None:
        # The pre-existing bug: a high-cost region was handed the raw budget as if
        # it were baseline dollars. The LLM must instead receive budget ÷ multiplier
        # so the post-multiplier total lands near the user's real budget.
        # CH (1.45) × city (1.15) = 1.6675 → 1.67. A $85 baseline plan → 141.95,
        # inside the $150 band [127.5, 150], so no retry.
        with mock.patch(
            "app.mealplan.llm.generate_budget_plan", return_value=self._plan(85.0)
        ) as gen:
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self._body(budget=150, country="CH", area_type="city"),
                headers=self._headers(),
            )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 1)
        self.assertAlmostEqual(gen.call_args.kwargs["budget"], 150 / 1.67, places=2)
        self.assertIsNone(gen.call_args.kwargs["prior_total"])  # first pass

    def test_under_band_triggers_one_retry_and_ships_fuller_plan(self) -> None:
        # US/suburb, budget 100, band [85, 100]. First plan $40 (under) → one retry;
        # retry returns a $92 plan (in band) → that fuller plan ships.
        with mock.patch(
            "app.mealplan.llm.generate_budget_plan",
            side_effect=[self._plan(40.0, title="Cheap"), self._plan(92.0, title="Full")],
        ) as gen:
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self._body(area_type="suburb"),
                headers=self._headers(),
            )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 2)
        # Retry was fed the first plan's baseline total as prior_total.
        self.assertAlmostEqual(gen.call_args_list[1].kwargs["prior_total"], 40.0, places=2)
        data = r.json()
        self.assertEqual(len(data["recipes"]), 1)
        self.assertAlmostEqual(data["recipes"][0]["estimated_cost"]["amount"], 92.0, places=2)
        self.assertEqual(data["recipes"][0]["recipe"]["title"], "Full-0")

    def test_still_under_after_retry_ships_best_effort_and_logs(self) -> None:
        # Both passes come in under the band → ship the better one, log the miss.
        with mock.patch(
            "app.mealplan.llm.generate_budget_plan",
            side_effect=[self._plan(40.0), self._plan(50.0)],
        ) as gen:
            with self.assertLogs("uvicorn.error", level="WARNING") as logs:
                r = self.client.post(
                    "/v1/meal-plan/budget",
                    json=self._body(area_type="suburb"),
                    headers=self._headers(),
                )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 2)
        # Best-effort: the larger sub-band plan ($50) ships.
        self.assertAlmostEqual(r.json()["recipes"][0]["estimated_cost"]["amount"], 50.0, places=2)
        self.assertTrue(any("under target" in m for m in logs.output))

    def test_selection_never_ships_a_plan_over_budget(self) -> None:
        # First plan under band → retry; retry overshoots budget ($130 > $100), so
        # the under-budget first plan is kept despite being below the band.
        with mock.patch(
            "app.mealplan.llm.generate_budget_plan",
            side_effect=[self._plan(40.0, title="Under"), self._plan(130.0, title="Over")],
        ) as gen:
            with self.assertLogs("uvicorn.error", level="WARNING"):
                r = self.client.post(
                    "/v1/meal-plan/budget",
                    json=self._body(area_type="suburb"),
                    headers=self._headers(),
                )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 2)
        self.assertAlmostEqual(r.json()["recipes"][0]["estimated_cost"]["amount"], 40.0, places=2)
        self.assertEqual(r.json()["recipes"][0]["recipe"]["title"], "Under-0")

    def test_retry_llm_error_keeps_first_plan(self) -> None:
        from app.pipeline import llm

        with mock.patch(
            "app.mealplan.llm.generate_budget_plan",
            side_effect=[self._plan(40.0), llm.LLMError("llm_error", "boom")],
        ) as gen:
            with self.assertLogs("uvicorn.error", level="WARNING"):
                r = self.client.post(
                    "/v1/meal-plan/budget",
                    json=self._body(area_type="suburb"),
                    headers=self._headers(),
                )
        self.assertEqual(r.status_code, 200, r.text)  # corrective failure ≠ request failure
        self.assertEqual(gen.call_count, 2)
        self.assertAlmostEqual(r.json()["recipes"][0]["estimated_cost"]["amount"], 40.0, places=2)

    def test_only_the_selected_plan_is_saved_to_cache(self) -> None:
        # Save-once: a discarded corrective attempt must not pollute the shared cache.
        with mock.patch(
            "app.mealplan.llm.generate_budget_plan",
            side_effect=[self._plan(40.0, title="Cheap"), self._plan(90.0, title="Full")],
        ):
            with mock.patch("app.mealplan.db.save_recipe") as save:
                r = self.client.post(
                    "/v1/meal-plan/budget",
                    json=self._body(area_type="suburb"),
                    headers=self._headers(),
                )
        self.assertEqual(r.status_code, 200, r.text)
        # Only the selected ($90) plan's single recipe is persisted, not both attempts.
        self.assertEqual(save.call_count, 1)
        self.assertEqual(save.call_args.args[0].title, "Full-0")


if __name__ == "__main__":
    unittest.main()
