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
    def setUp(self) -> None:
        self._orig = config.MIN_BUDGET_PER_PERSON
        config.MIN_BUDGET_PER_PERSON = 25

    def tearDown(self) -> None:
        config.MIN_BUDGET_PER_PERSON = self._orig

    def test_scales_per_person(self) -> None:
        self.assertEqual(budget.min_budget(1), 25)
        self.assertEqual(budget.min_budget(2), 50)
        self.assertEqual(budget.min_budget(4), 100)

    def test_increasing_household_raises_minimum(self) -> None:
        self.assertGreater(budget.min_budget(4), budget.min_budget(2))

    def test_rounds_to_nearest_five(self) -> None:
        config.MIN_BUDGET_PER_PERSON = 23  # 3 people = 69 -> nearest 5 = 70
        self.assertEqual(budget.min_budget(3), 70)
        config.MIN_BUDGET_PER_PERSON = 22  # 3 people = 66 -> nearest 5 = 65
        self.assertEqual(budget.min_budget(3), 65)

    def test_household_clamped_to_at_least_one(self) -> None:
        self.assertEqual(budget.min_budget(0), 25)
        self.assertEqual(budget.min_budget(-3), 25)


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
        self._orig_min = config.MIN_BUDGET_PER_PERSON
        self._path = _fresh_db()
        config.DB_PATH = self._path
        config.DATABASE_URL = None
        config.APP_KEY = None  # fail-open: no X-App-Key needed
        config.MIN_BUDGET_PER_PERSON = 25
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
        config.MIN_BUDGET_PER_PERSON = self._orig_min
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

    def test_free_user_cannot_call_endpoint(self) -> None:
        # No X-Pro-Entitled → 403 pro_required, before any generation.
        r = self.client.post("/v1/meal-plan/budget", json=self._body(), headers=self._headers(pro=False))
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["detail"]["error_code"], "pro_required")

    def test_below_minimum_is_rejected_even_if_client_missed_it(self) -> None:
        # household 4 → min 100; a client that sent 60 anyway is rejected server-side.
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=self._fake_recipes()) as gen:
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self._body(budget=60, household_size=4),
                headers=self._headers(),
            )
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["detail"]["error_code"], "budget_below_minimum")
        self.assertEqual(r.json()["detail"]["min_budget"], 100)
        gen.assert_not_called()  # rejected before spending on generation

    def test_happy_path_applies_regional_multiplier_and_saves_recipe(self) -> None:
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=self._fake_recipes()):
            r = self.client.post("/v1/meal-plan/budget", json=self._body(), headers=self._headers())
        self.assertEqual(r.status_code, 200, r.text)
        data = r.json()
        # US (1.00) × city (1.15) = 1.15
        self.assertEqual(data["regional_multiplier"], 1.15)
        self.assertEqual(len(data["recipes"]), 1)
        planned = data["recipes"][0]
        # baseline 10.0 × 1.15 = 11.5
        self.assertAlmostEqual(planned["estimated_cost"]["amount"], 11.5, places=2)
        self.assertEqual(planned["health_signal"], "Veg-forward")
        # Recipe was written to the shared cache under its synthetic key.
        self.assertIsNotNone(db.get_recipe(planned["recipe"]["recipe_id"]))

    def test_unknown_location_uses_default_multiplier(self) -> None:
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=self._fake_recipes()):
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self._body(country="ZZ", area_type="spacestation"),
                headers=self._headers(),
            )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["regional_multiplier"], 1.0)


if __name__ == "__main__":
    unittest.main()
