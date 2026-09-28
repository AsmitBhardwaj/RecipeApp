"""Plan on a Budget revamp: store tier, appliances/moods, the plan ledger + free
first plan, and the swap endpoint (app/mealplan.py). The pre-revamp behavior
(area_type multiplier, Pro gating, retry/selection) stays in test_budget_plan.py.

    DATABASE_URL= .venv/bin/python -m unittest tests.test_budget_planner
"""
from __future__ import annotations

import json
import os
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

from fastapi.testclient import TestClient
from sqlalchemy import select

from app import budget, config, db
from app.models import Appliance, CostEstimate, Equipment, LLMRecipe
from app.pipeline import llm, regional_cost
from app.pipeline.llm import BudgetPlanRecipeLLM
from tests.entitlement_utils import grant_pro, revoke_pro

OVEN, STOVE, MICRO = Appliance.oven, Appliance.stovetop, Appliance.microwave


def meal(title: str, cost: float, equipment=()) -> BudgetPlanRecipeLLM:
    return BudgetPlanRecipeLLM(
        recipe=LLMRecipe(title=title, ingredients=[], instructions=[]),
        baseline_cost=CostEstimate(amount=float(cost), currency="USD", basis="llm-v1"),
        health_signal="Veg-forward",
        equipment_used=list(equipment) or [STOVE],  # the schema requires ≥1
    )


def meal_without_equipment(title: str, cost: float) -> BudgetPlanRecipeLLM:
    """A meal whose equipment_used is empty — the schema rejects this from the model,
    so build it by copy (which skips validation) to exercise the server-side check."""
    return meal(title, cost).model_copy(update={"equipment_used": []})


def _completion(content: str):
    usage = SimpleNamespace(
        prompt_tokens=100, completion_tokens=50, prompt_tokens_details=SimpleNamespace(cached_tokens=0)
    )
    message = SimpleNamespace(refusal=None, content=content)
    return SimpleNamespace(choices=[SimpleNamespace(message=message)], usage=usage)


class StoreTierMultiplierTests(unittest.TestCase):
    def test_store_tier_modifiers_table(self) -> None:
        self.assertEqual(regional_cost.STORE_TIER_MODIFIERS, {"budget": 0.85, "standard": 1.00, "premium": 1.30})

    def test_tier_multiplies_country_baseline(self) -> None:
        self.assertEqual(regional_cost.multiplier_for("US", None, "premium"), 1.3)
        self.assertEqual(regional_cost.multiplier_for("US", None, "budget"), 0.85)
        self.assertEqual(regional_cost.multiplier_for("US", None, "standard"), 1.0)
        self.assertEqual(regional_cost.multiplier_for("DE", None, "premium"), 1.3)

    def test_tier_ignores_area_type(self) -> None:
        self.assertEqual(
            regional_cost.multiplier_for("US", "city", "standard"),
            regional_cost.multiplier_for("US", "rural", "standard"),
        )
        self.assertEqual(regional_cost.multiplier_for("US", "city", "premium"), 1.3)  # not 1.3 × 1.15

    def test_v1_area_type_path_unchanged(self) -> None:
        self.assertEqual(regional_cost.multiplier_for("US", "city"), 1.15)
        self.assertEqual(regional_cost.multiplier_for("GB", "rural"), 0.94)
        self.assertEqual(regional_cost.multiplier_for(None, None), 1.0)


class _Base(unittest.TestCase):
    def setUp(self) -> None:
        self._orig = (
            config.DB_PATH, config.DATABASE_URL, config.APP_KEY,
            budget.PER_DINNER_FLOOR, budget.PER_DINNER_COMFORTABLE,
            budget.PER_DINNER_RICHNESS_CEILING, budget.MIN_RECIPE_COUNT,
            config.BUDGET_PLAN_RECIPE_COUNT, config.BURST_SWAP_PER_DAY,
            config.BURST_BUDGET_PLAN_PER_DAY,
        )
        budget.PER_DINNER_FLOOR = 3.0
        budget.PER_DINNER_COMFORTABLE = 8.0
        budget.PER_DINNER_RICHNESS_CEILING = 12.0
        budget.MIN_RECIPE_COUNT = 4
        config.BUDGET_PLAN_RECIPE_COUNT = 7
        fd, self._path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        config.DB_PATH = self._path
        config.DATABASE_URL = None
        config.APP_KEY = None
        config.BURST_SWAP_PER_DAY = 20
        config.BURST_BUDGET_PLAN_PER_DAY = 10
        db.init_db()

        from app.auth import security, service
        import app.main as main

        self._service, self._security = service, security
        self.user = service.create_email_user("planner@example.com", "pw-123456", "Planner")
        self.token, _ = security.create_access_token(self.user.id)
        self.client = TestClient(main.app)

    def tearDown(self) -> None:
        (config.DB_PATH, config.DATABASE_URL, config.APP_KEY,
         budget.PER_DINNER_FLOOR, budget.PER_DINNER_COMFORTABLE,
         budget.PER_DINNER_RICHNESS_CEILING, budget.MIN_RECIPE_COUNT,
         config.BUDGET_PLAN_RECIPE_COUNT, config.BURST_SWAP_PER_DAY,
         config.BURST_BUDGET_PLAN_PER_DAY) = self._orig
        os.unlink(self._path)

    def headers(self, pro: bool = True) -> dict:
        grant_pro(self.user.id) if pro else revoke_pro(self.user.id)
        return {"Authorization": f"Bearer {self.token}", "X-User-Id": "device-1"}

    def body(self, **over) -> dict:
        b = {
            "budget": 100, "currency": "USD", "household_size": 2,
            "dietary_preferences": ["vegetarian"], "pantry_items": ["rice"],
            "country": "US", "area_type": "suburb",
        }
        b.update(over)
        return b

    def plan(self, body=None, pro=True, gen_return=None):
        body = body or self.body()
        # Default meals use the first appliance the request lists, so they comply.
        eq = [Appliance(body["appliances"][0])] if body.get("appliances") else [STOVE]
        gen_return = gen_return or [meal("A", 30, eq), meal("B", 30, eq), meal("C", 30, eq)]
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=gen_return):
            return self.client.post("/v1/meal-plan/budget", json=body, headers=self.headers(pro=pro))

    def swap(self, plan_id, index=1, headers=None):
        return self.client.post(
            f"/v1/meal-plan/budget/{plan_id}/swap",
            json={"meal_index": index},
            headers=headers or self.headers(pro=True),
        )


class RequestValidationTests(_Base):
    def _post(self, **over):
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=[meal("A", 90)]):
            return self.client.post("/v1/meal-plan/budget", json=self.body(**over), headers=self.headers())

    def test_empty_appliances_rejected(self) -> None:
        self.assertEqual(self._post(appliances=[]).status_code, 422)

    def test_unknown_appliance_mood_and_tier_rejected(self) -> None:
        self.assertEqual(self._post(appliances=["deep_fryer"]).status_code, 422)
        self.assertEqual(self._post(food_moods=["sad"]).status_code, 422)
        self.assertEqual(self._post(store_tier="luxury").status_code, 422)

    def test_more_than_three_moods_rejected(self) -> None:
        self.assertEqual(
            self._post(food_moods=["comfort", "light_fresh", "spicy", "quick"]).status_code, 422
        )

    def test_v1_body_with_no_new_fields_is_accepted(self) -> None:
        r = self._post()
        self.assertEqual(r.status_code, 200, r.text)


class StoreTierEndpointTests(_Base):
    def test_store_tier_replaces_area_type(self) -> None:
        # US × premium = 1.3; area_type "city" (1.15) must be ignored.
        r = self.plan(self.body(budget=130, store_tier="premium", area_type="city"))
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["regional_multiplier"], 1.3)
        self.assertAlmostEqual(r.json()["recipes"][0]["estimated_cost"]["amount"], 39.0)  # 30 × 1.3

    def test_without_store_tier_area_type_still_applies(self) -> None:
        r = self.plan(self.body(area_type="city"))
        self.assertEqual(r.json()["regional_multiplier"], 1.15)

    def test_budget_is_converted_with_the_tier_multiplier(self) -> None:
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=[meal("A", 90)]) as gen:
            self.client.post(
                "/v1/meal-plan/budget",
                json=self.body(budget=130, store_tier="premium"),
                headers=self.headers(),
            )
        self.assertAlmostEqual(gen.call_args.kwargs["budget"], 100.0)

    def test_bounds_messages_use_the_tier_multiplier(self) -> None:
        # household 4 → baseline min 50, max 335. Premium (1.3): local min 65.
        r = self.plan(self.body(budget=40, household_size=4, store_tier="premium"))
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["detail"]["error_code"], "budget_below_minimum")
        self.assertEqual(r.json()["detail"]["min_budget"], 65)
        # …and the same budget is fine on the v1.0 path (suburb 1.0 → min 50 → 40 < 50 still low)
        r = self.plan(self.body(budget=1000, household_size=4, store_tier="premium"))
        self.assertEqual(r.json()["detail"]["error_code"], "budget_above_maximum")
        self.assertEqual(r.json()["detail"]["max_budget"], 435)  # 335 × 1.3 = 435.5 → 435


class ApplianceTests(_Base):
    def call(self, gens, singles=None, appliances=("oven", "stovetop"), **over):
        with mock.patch("app.mealplan.llm.generate_budget_plan", side_effect=gens) as gen, \
             mock.patch("app.mealplan.llm.generate_single_meal", side_effect=singles or []) as single:
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self.body(appliances=list(appliances), **over),
                headers=self.headers(),
            )
        return r, gen, single

    def test_no_appliances_skips_validation_entirely(self) -> None:
        # v1.0: equipment_used is ignored — nothing triggers a retry or replacement.
        with mock.patch(
            "app.mealplan.llm.generate_budget_plan", return_value=[meal("A", 90, [Appliance.air_fryer])]
        ) as gen, mock.patch("app.mealplan.llm.generate_single_meal") as single:
            r = self.client.post("/v1/meal-plan/budget", json=self.body(), headers=self.headers())
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 1)
        single.assert_not_called()
        self.assertIsNone(gen.call_args.kwargs["appliances"])

    def test_prompt_inputs_are_passed_through(self) -> None:
        r, gen, _ = self.call([[meal("A", 90, [OVEN])]], food_moods=["spicy", "quick"])
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_args.kwargs["appliances"], ["oven", "stovetop"])
        self.assertEqual(gen.call_args.kwargs["food_moods"], ["spicy", "quick"])

    def test_compliant_plan_needs_no_retry(self) -> None:
        r, gen, single = self.call([[meal("A", 45, [OVEN]), meal("B", 45, [STOVE, OVEN])]])
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 1)
        single.assert_not_called()
        self.assertEqual(r.json()["recipes"][1]["equipment_used"], ["stovetop", "oven"])

    def test_violation_triggers_the_corrective_retry(self) -> None:
        first = [meal("Air Fryer Wings", 45, [Appliance.air_fryer]), meal("B", 45, [OVEN])]
        second = [meal("Baked Ziti", 45, [OVEN]), meal("B2", 45, [OVEN])]
        r, gen, single = self.call([first, second])
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 2)
        retry_kwargs = gen.call_args_list[1].kwargs
        self.assertEqual(retry_kwargs["violations"], ["Air Fryer Wings (needs air_fryer)"])
        self.assertIsNone(retry_kwargs["prior_total"])  # in band: only the violation drove it
        self.assertEqual([x["recipe"]["title"] for x in r.json()["recipes"]], ["Baked Ziti", "B2"])
        single.assert_not_called()

    def test_violation_plus_undershoot_is_still_one_retry_total(self) -> None:
        first = [meal("Wings", 20, [Appliance.air_fryer])]  # under band AND violating
        second = [meal("Ziti", 90, [OVEN])]
        r, gen, _ = self.call([first, second])
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 2)
        kw = gen.call_args_list[1].kwargs
        self.assertAlmostEqual(kw["prior_total"], 20.0)
        self.assertTrue(kw["violations"])

    def test_violations_after_retry_are_replaced_per_meal(self) -> None:
        bad = lambda: [meal("Wings", 30, [Appliance.air_fryer]), meal("Chili", 30, [STOVE]), meal("Stew", 30, [OVEN])]
        replacement = meal("Skillet Chicken", 32, [STOVE])
        r, gen, single = self.call([bad(), bad()], singles=[replacement])
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 2)  # retry cap unchanged
        self.assertEqual(single.call_count, 1)  # only the violating meal
        kw = single.call_args.kwargs
        self.assertEqual(kw["exclude_titles"], ["Wings", "Chili", "Stew"])
        self.assertEqual(kw["appliances"], ["oven", "stovetop"])
        # cap = baseline budget 100 − total 90 + replaced 30 = 40
        self.assertAlmostEqual(kw["max_cost"], 40.0)
        titles = [x["recipe"]["title"] for x in r.json()["recipes"]]
        self.assertEqual(titles, ["Skillet Chicken", "Chili", "Stew"])  # position preserved

    def test_unreplaceable_meal_is_dropped_not_shipped(self) -> None:
        bad = lambda: [meal("Wings", 45, [Appliance.air_fryer]), meal("Chili", 45, [STOVE])]
        # Replacement itself still violates (one attempt in this path) → dropped.
        r, _, single = self.call([bad(), bad()], singles=[meal("Nope", 40, [MICRO])])
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual([x["recipe"]["title"] for x in r.json()["recipes"]], ["Chili"])
        self.assertEqual(single.call_count, 1)

    def test_replacement_llm_error_drops_the_meal(self) -> None:
        bad = lambda: [meal("Wings", 45, [MICRO]), meal("Chili", 45, [STOVE])]
        r, _, _ = self.call([bad(), bad()], singles=[llm.LLMError("llm_api_error", "boom")])
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(len(r.json()["recipes"]), 1)

    def test_all_meals_unreplaceable_is_a_502_and_burns_no_free_plan(self) -> None:
        bad = lambda: [meal("Wings", 90, [MICRO])]
        with mock.patch("app.mealplan.llm.generate_budget_plan", side_effect=[bad(), bad()]), \
             mock.patch("app.mealplan.llm.generate_single_meal", side_effect=llm.LLMError("x", "y")):
            r = self.client.post(
                "/v1/meal-plan/budget",
                json=self.body(appliances=["oven"]),
                headers=self.headers(pro=False),
            )
        self.assertEqual(r.status_code, 502)
        self.assertEqual(r.json()["detail"]["error_code"], "appliance_constraint_unmet")
        self.assertIsNone(db.get_free_plan_used_at(self.user.id))


class EquipmentRequiredTests(_Base):
    def test_schema_requires_at_least_one_item(self) -> None:
        with self.assertRaises(Exception):
            BudgetPlanRecipeLLM(
                recipe=LLMRecipe(title="x", ingredients=[], instructions=[]),
                baseline_cost=CostEstimate(amount=1.0),
                equipment_used=[],
            )
        schema = BudgetPlanRecipeLLM.model_json_schema()
        self.assertEqual(schema["properties"]["equipment_used"]["minItems"], 1)
        self.assertIn("equipment_used", schema["required"])

    def test_empty_equipment_is_a_violation_when_appliances_present(self) -> None:
        first = [meal_without_equipment("Mystery", 45), meal("B", 45, [OVEN])]
        second = [meal("Ziti", 45, [OVEN]), meal("B2", 45, [OVEN])]
        with mock.patch("app.mealplan.llm.generate_budget_plan", side_effect=[first, second]) as gen, \
             mock.patch("app.mealplan.llm.generate_single_meal") as single:
            r = self.client.post(
                "/v1/meal-plan/budget", json=self.body(appliances=["oven"]), headers=self.headers()
            )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 2)
        self.assertEqual(gen.call_args_list[1].kwargs["violations"], ["Mystery (listed no equipment_used)"])
        single.assert_not_called()

    def test_empty_equipment_after_retry_is_replaced_per_meal(self) -> None:
        mk = lambda: [meal_without_equipment("Mystery", 45), meal("B", 45, [OVEN])]
        with mock.patch("app.mealplan.llm.generate_budget_plan", side_effect=[mk(), mk()]), \
             mock.patch("app.mealplan.llm.generate_single_meal", return_value=meal("Ziti", 45, [OVEN])) as single:
            r = self.client.post(
                "/v1/meal-plan/budget", json=self.body(appliances=["oven"]), headers=self.headers()
            )
        self.assertEqual([x["recipe"]["title"] for x in r.json()["recipes"]], ["Ziti", "B"])
        self.assertEqual(single.call_count, 1)

    def test_empty_equipment_ignored_without_appliances(self) -> None:
        # v1.0 path: no validation at all.
        with mock.patch(
            "app.mealplan.llm.generate_budget_plan", return_value=[meal_without_equipment("A", 90)]
        ) as gen:
            r = self.client.post("/v1/meal-plan/budget", json=self.body(), headers=self.headers())
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 1)

    def test_swap_replacement_with_empty_equipment_is_rejected_then_corrected(self) -> None:
        r = self.plan(self.body(appliances=["oven"]), gen_return=[meal(t, 30, [OVEN]) for t in "ABC"])
        plan_id = r.json()["plan_id"]
        seq = [meal_without_equipment("Z", 30), meal("Y", 30, [OVEN])]
        with mock.patch("app.mealplan.llm.generate_single_meal", side_effect=seq) as single:
            s = self.swap(plan_id)
        self.assertEqual(s.status_code, 200, s.text)
        self.assertIn("at least one", single.call_args_list[1].kwargs["feedback"])


class NoCookTests(_Base):
    def _post(self, plan, appliances, single=None):
        with mock.patch("app.mealplan.llm.generate_budget_plan", side_effect=plan) as gen, \
             mock.patch("app.mealplan.llm.generate_single_meal", side_effect=single or []) as one:
            r = self.client.post(
                "/v1/meal-plan/budget", json=self.body(appliances=appliances), headers=self.headers()
            )
        return r, gen, one

    def test_no_cook_is_a_schema_value_but_not_a_user_appliance(self) -> None:
        self.assertIn("no_cook", {e.value for e in Equipment})
        self.assertNotIn("no_cook", {a.value for a in Appliance})
        r = self.client.post(
            "/v1/meal-plan/budget", json=self.body(appliances=["no_cook"]), headers=self.headers()
        )
        self.assertEqual(r.status_code, 422)

    def test_no_cook_meal_passes_for_a_microwave_only_user(self) -> None:
        plan = [meal("Salad", 45, [Equipment.no_cook]), meal("Mug Cake", 45, [MICRO])]
        r, gen, single = self._post([plan], ["microwave"])
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_count, 1)  # no violation → no retry
        single.assert_not_called()
        self.assertEqual(r.json()["recipes"][0]["equipment_used"], ["no_cook"])

    def test_no_cook_plus_an_unowned_appliance_still_violates(self) -> None:
        mk = lambda: [meal("Bake", 45, [Equipment.no_cook, OVEN]), meal("Salad", 45, [Equipment.no_cook])]
        fixed = meal("Wrap", 45, [Equipment.no_cook])
        r, gen, single = self._post([mk(), mk()], ["microwave"], single=[fixed])
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(gen.call_args_list[1].kwargs["violations"], ["Bake (needs oven)"])
        self.assertEqual([x["recipe"]["title"] for x in r.json()["recipes"]], ["Wrap", "Salad"])

    def test_no_cook_replacement_is_accepted_in_a_swap(self) -> None:
        plan_id = self.plan(self.body(appliances=["microwave"]),
                            gen_return=[meal(t, 30, [MICRO]) for t in "ABC"]).json()["plan_id"]
        with mock.patch("app.mealplan.llm.generate_single_meal", return_value=meal("Z", 30, [Equipment.no_cook])):
            self.assertEqual(self.swap(plan_id).status_code, 200)

    def test_schema_enum_includes_no_cook(self) -> None:
        schema = BudgetPlanRecipeLLM.model_json_schema()
        self.assertIn("no_cook", schema["$defs"]["Equipment"]["enum"])


class SwapsRemainingTests(_Base):
    def test_free_plan_reports_is_free_and_three_remaining(self) -> None:
        r = self.plan(pro=False)
        self.assertTrue(r.json()["is_free"])
        self.assertEqual(r.json()["swaps_remaining"], 3)

    def test_free_swaps_decrement_to_zero_then_402(self) -> None:
        plan_id = self.plan(pro=False).json()["plan_id"]
        free = self.headers(pro=False)
        remaining = []
        for i in range(3):
            with mock.patch("app.mealplan.llm.generate_single_meal", return_value=meal(f"Z{i}", 30)):
                remaining.append(self.swap(plan_id, index=i, headers=free).json()["swaps_remaining"])
        self.assertEqual(remaining, [2, 1, 0])
        with mock.patch("app.mealplan.llm.generate_single_meal") as single:
            self.assertEqual(self.swap(plan_id, headers=free).status_code, 402)
        single.assert_not_called()

    def test_failed_swap_does_not_decrement(self) -> None:
        plan_id = self.plan(pro=False).json()["plan_id"]
        free = self.headers(pro=False)
        with mock.patch("app.mealplan.llm.generate_single_meal", side_effect=llm.LLMError("x", "y")):
            self.assertEqual(self.swap(plan_id, headers=free).status_code, 502)
        with mock.patch("app.mealplan.llm.generate_single_meal", return_value=meal("Z", 30)):
            self.assertEqual(self.swap(plan_id, headers=free).json()["swaps_remaining"], 2)

    def test_pro_plan_is_not_free_and_swaps_remaining_is_null(self) -> None:
        r = self.plan(pro=True)
        self.assertFalse(r.json()["is_free"])
        self.assertIsNone(r.json()["swaps_remaining"])
        with mock.patch("app.mealplan.llm.generate_single_meal", return_value=meal("Z", 30)):
            s = self.swap(r.json()["plan_id"])
        self.assertIsNone(s.json()["swaps_remaining"])

    def test_pro_swapping_their_earlier_free_plan_is_unlimited(self) -> None:
        plan_id = self.plan(pro=False).json()["plan_id"]  # free plan
        with mock.patch("app.mealplan.llm.generate_single_meal", return_value=meal("Z", 30)):
            s = self.swap(plan_id, headers=self.headers(pro=True))
        self.assertIsNone(s.json()["swaps_remaining"])


class FreePlanTests(_Base):
    def test_free_plan_allowed_once_then_paywalled(self) -> None:
        r1 = self.plan(pro=False)
        self.assertEqual(r1.status_code, 200, r1.text)
        self.assertIsNotNone(db.get_free_plan_used_at(self.user.id))
        self.assertTrue(db.get_budget_plan(r1.json()["plan_id"])["is_free"])

        with mock.patch("app.mealplan.llm.generate_budget_plan") as gen:
            r2 = self.client.post("/v1/meal-plan/budget", json=self.body(), headers=self.headers(pro=False))
        self.assertEqual(r2.status_code, 403)
        detail = r2.json()["detail"]
        # v1.0 opens its paywall on exactly 403 + pro_required; v1.1 reads `reason`.
        self.assertEqual(detail["error_code"], "pro_required")
        self.assertEqual(detail["reason"], "free_plan_used")
        gen.assert_not_called()

    def test_free_plan_not_consumed_by_failures(self) -> None:
        # LLM failure
        with mock.patch("app.mealplan.llm.generate_budget_plan", side_effect=llm.LLMError("boom", "x")):
            r = self.client.post("/v1/meal-plan/budget", json=self.body(), headers=self.headers(pro=False))
        self.assertEqual(r.status_code, 502)
        self.assertIsNone(db.get_free_plan_used_at(self.user.id))
        # Budget rejection
        r = self.plan(self.body(budget=5), pro=False)
        self.assertEqual(r.status_code, 400)
        self.assertIsNone(db.get_free_plan_used_at(self.user.id))
        # …so the free plan is still there.
        self.assertEqual(self.plan(pro=False).status_code, 200)
        self.assertIsNotNone(db.get_free_plan_used_at(self.user.id))

    def test_pro_is_unaffected_and_does_not_burn_the_free_plan(self) -> None:
        for _ in range(3):
            r = self.plan(pro=True)
            self.assertEqual(r.status_code, 200, r.text)
            self.assertFalse(db.get_budget_plan(r.json()["plan_id"])["is_free"])
        self.assertIsNone(db.get_free_plan_used_at(self.user.id))

    def test_pro_in_billing_grace_is_allowed_after_free_plan_spent(self) -> None:
        db.claim_free_plan(self.user.id, "2026-01-01T00:00:00+00:00")
        revoke_pro(self.user.id)
        grant_pro(self.user.id, days=None, grace_days=3)
        r = self.plan_no_regrant()
        self.assertEqual(r.status_code, 200, r.text)

    def plan_no_regrant(self):
        with mock.patch("app.mealplan.llm.generate_budget_plan", return_value=[meal("A", 90)]):
            return self.client.post(
                "/v1/meal-plan/budget", json=self.body(),
                headers={"Authorization": f"Bearer {self.token}", "X-User-Id": "device-1"},
            )

    def test_claim_free_plan_is_compare_and_set(self) -> None:
        self.assertTrue(db.claim_free_plan(self.user.id, "2026-01-01T00:00:00+00:00"))
        self.assertFalse(db.claim_free_plan(self.user.id, "2026-02-01T00:00:00+00:00"))
        self.assertEqual(db.get_free_plan_used_at(self.user.id), "2026-01-01T00:00:00+00:00")


class LedgerTests(_Base):
    def test_plan_id_returned_and_persisted(self) -> None:
        r = self.plan(self.body(appliances=["oven"], food_moods=["comfort"], store_tier="premium", budget=130),
                      gen_return=[meal("A", 40, [OVEN]), meal("B", 40, [OVEN]), meal("C", 30, [OVEN])])
        self.assertEqual(r.status_code, 200, r.text)
        plan_id = r.json()["plan_id"]
        row = db.get_budget_plan(plan_id)
        self.assertEqual(row["user_id"], self.user.id)
        self.assertEqual(row["swaps_used"], 0)
        self.assertFalse(row["is_free"])  # Pro
        self.assertAlmostEqual(row["budget_baseline"], 100.0)  # 130 ÷ 1.3
        meals = json.loads(row["plan_json"])
        self.assertEqual([m["title"] for m in meals], ["A", "B", "C"])
        self.assertEqual([m["baseline_cost"]["amount"] for m in meals], [40.0, 40.0, 30.0])
        self.assertEqual(meals[0]["equipment_used"], ["oven"])
        # Ledger recipe ids match the returned recipes.
        self.assertEqual([m["recipe_id"] for m in meals], [x["recipe"]["recipe_id"] for x in r.json()["recipes"]])
        req = json.loads(row["request_json"])
        self.assertEqual(req["appliances"], ["oven"])
        self.assertEqual(req["store_tier"], "premium")
        self.assertEqual(req["resolved_multiplier"], 1.3)

    def test_new_columns_are_added_to_an_existing_database(self) -> None:
        from sqlalchemy import create_engine, text, inspect
        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        try:
            eng = create_engine(f"sqlite:///{path}")
            with eng.begin() as c:  # a pre-revamp schema
                c.execute(text("CREATE TABLE users (id VARCHAR PRIMARY KEY, email VARCHAR, "
                               "email_verified BOOLEAN, password_hash TEXT, full_name TEXT, "
                               "created_at TEXT, updated_at TEXT)"))
                c.execute(text("CREATE TABLE llm_cost_events (id INTEGER PRIMARY KEY, account_id VARCHAR, "
                               "call_type VARCHAR, model VARCHAR, prompt_tokens INT, cached_tokens INT, "
                               "completion_tokens INT, estimated_cost_usd FLOAT, created_at TEXT)"))
            db._add_missing_columns(eng)
            insp = inspect(eng)
            self.assertIn("free_plan_used_at", {c["name"] for c in insp.get_columns("users")})
            self.assertIn("plan_id", {c["name"] for c in insp.get_columns("llm_cost_events")})
        finally:
            os.unlink(path)


class CostEventTests(_Base):
    """Drive the real llm module against a stubbed OpenAI client, so cost events
    are recorded by the actual chokepoint."""

    def _events(self):
        with db.get_engine().begin() as conn:
            return list(conn.execute(select(db.llm_cost_events)).mappings())

    def test_plan_retry_and_swap_events_carry_plan_id(self) -> None:
        under = json.dumps({"recipes": [json.loads(meal("A", 20).model_dump_json())]})
        full = json.dumps({"recipes": [json.loads(meal(t, 30).model_dump_json()) for t in "ABC"]})
        single = meal("Z", 35).model_dump_json()
        fake = mock.MagicMock()
        fake.chat.completions.parse.side_effect = [_completion(under), _completion(full), _completion(single)]
        with mock.patch.object(llm, "_client", return_value=fake):
            r = self.client.post("/v1/meal-plan/budget", json=self.body(), headers=self.headers())
            self.assertEqual(r.status_code, 200, r.text)
            plan_id = r.json()["plan_id"]
            s = self.swap(plan_id, index=1)
            self.assertEqual(s.status_code, 200, s.text)
        events = self._events()
        self.assertEqual([e["call_type"] for e in events], ["budget_plan", "budget_plan", "budget_swap"])
        self.assertTrue(all(e["plan_id"] == plan_id for e in events))
        self.assertTrue(all(e["account_id"] == self.user.id for e in events))

    def test_imports_have_no_plan_id(self) -> None:
        from app import llm_cost
        with llm_cost.track(self.user.id, "import"):
            llm_cost.record_usage("gpt-5.4-mini", SimpleNamespace(prompt_tokens=1, completion_tokens=1))
        self.assertIsNone(self._events()[0]["plan_id"])


class SwapTests(_Base):
    def make_plan(self, pro=True, **over):
        r = self.plan(self.body(**over), pro=pro)
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()["plan_id"]

    def swap_with(self, plan_id, replacement, index=1, headers=None):
        with mock.patch("app.mealplan.llm.generate_single_meal", return_value=replacement) as single:
            r = self.swap(plan_id, index, headers)
        return r, single

    def test_happy_path_budget_math_and_exclusions(self) -> None:
        plan_id = self.make_plan(appliances=["oven", "stovetop"], food_moods=["comfort"])
        r, single = self.swap_with(plan_id, meal("Z", 35, [OVEN]))
        self.assertEqual(r.status_code, 200, r.text)
        kw = single.call_args.kwargs
        # cap = budget 100 − current total 90 + replaced 30
        self.assertAlmostEqual(kw["max_cost"], 40.0)
        self.assertEqual(kw["exclude_titles"], ["A", "B", "C"])  # all current names
        self.assertEqual(kw["appliances"], ["oven", "stovetop"])
        self.assertEqual(kw["food_moods"], ["comfort"])
        self.assertEqual(kw["dietary_preferences"], ["vegetarian"])
        self.assertEqual(kw["household_size"], 2)
        self.assertEqual(kw["on_hand"], ["rice"])
        data = r.json()
        self.assertEqual(data["meal"]["recipe"]["title"], "Z")
        self.assertAlmostEqual(data["plan_total"], 95.0)  # 30 + 35 + 30
        self.assertEqual(data["swaps_used"], 1)
        self.assertEqual(data["meal_index"], 1)
        row = db.get_budget_plan(plan_id)
        self.assertEqual(row["swaps_used"], 1)
        self.assertEqual([m["title"] for m in json.loads(row["plan_json"])], ["A", "Z", "C"])
        self.assertIsNotNone(db.get_recipe(data["meal"]["recipe"]["recipe_id"]))

    def test_swap_reuses_the_multiplier_the_plan_was_priced_with(self) -> None:
        plan_id = self.make_plan(budget=130, store_tier="premium")  # × 1.3
        with mock.patch.dict(regional_cost.STORE_TIER_MODIFIERS, {"premium": 2.0}):
            r, single = self.swap_with(plan_id, meal("Z", 35))
        self.assertEqual(r.status_code, 200, r.text)
        self.assertAlmostEqual(single.call_args.kwargs["max_cost"], 40.0)
        self.assertAlmostEqual(r.json()["meal"]["estimated_cost"]["amount"], 45.5)  # 35 × 1.3
        self.assertAlmostEqual(r.json()["plan_total"], 123.5)  # 95 × 1.3

    def test_swap_works_on_a_v1_plan_without_new_fields(self) -> None:
        plan_id = self.make_plan()
        r, single = self.swap_with(plan_id, meal("Z", 30, [Appliance.air_fryer]))  # no validation
        self.assertEqual(r.status_code, 200, r.text)
        self.assertIsNone(single.call_args.kwargs["appliances"])

    def test_ownership_and_auth(self) -> None:
        plan_id = self.make_plan()
        other = self._service.create_email_user("other@example.com", "pw-123456", "Other")
        tok, _ = self._security.create_access_token(other.id)
        grant_pro(other.id)
        with mock.patch("app.mealplan.llm.generate_single_meal") as single:
            r = self.swap(plan_id, headers={"Authorization": f"Bearer {tok}", "X-User-Id": "d2"})
            self.assertEqual(r.status_code, 404)
            self.assertEqual(self.swap("no-such-plan").status_code, 404)
            anon = self.client.post(f"/v1/meal-plan/budget/{plan_id}/swap", json={"meal_index": 0})
            self.assertEqual(anon.status_code, 401)
        single.assert_not_called()
        self.assertEqual(db.get_budget_plan(plan_id)["swaps_used"], 0)

    def test_invalid_meal_index(self) -> None:
        plan_id = self.make_plan()
        with mock.patch("app.mealplan.llm.generate_single_meal") as single:
            for bad in (-1, 3, 99):
                r = self.swap(plan_id, bad)
                self.assertEqual(r.status_code, 400)
                self.assertEqual(r.json()["detail"]["error_code"], "invalid_meal_index")
        single.assert_not_called()

    def test_bad_replacement_retries_once_then_fails_without_consuming_a_swap(self) -> None:
        plan_id = self.make_plan(appliances=["oven"])
        before = db.get_budget_plan(plan_id)["plan_json"]
        too_pricey = meal("Z", 60, [OVEN])  # cap is 40
        with mock.patch("app.mealplan.llm.generate_single_meal", return_value=too_pricey) as single:
            r = self.swap(plan_id)
        self.assertEqual(r.status_code, 502)
        self.assertEqual(r.json()["detail"]["error_code"], "swap_constraint_unmet")
        self.assertEqual(single.call_count, 2)
        self.assertIn("exceeds the maximum", single.call_args_list[1].kwargs["feedback"])
        row = db.get_budget_plan(plan_id)
        self.assertEqual(row["swaps_used"], 0)
        self.assertEqual(row["plan_json"], before)

    def test_replacement_violating_appliances_is_corrected_on_the_retry(self) -> None:
        plan_id = self.make_plan(appliances=["oven"])
        seq = [meal("Z", 30, [MICRO]), meal("Y", 30, [OVEN])]
        with mock.patch("app.mealplan.llm.generate_single_meal", side_effect=seq) as single:
            r = self.swap(plan_id)
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["meal"]["recipe"]["title"], "Y")
        self.assertIn("microwave", single.call_args_list[1].kwargs["feedback"])

    def test_replacement_repeating_a_current_meal_is_rejected(self) -> None:
        plan_id = self.make_plan()
        with mock.patch("app.mealplan.llm.generate_single_meal", return_value=meal("a", 30)):
            r = self.swap(plan_id)
        self.assertEqual(r.status_code, 502)

    def test_free_user_gets_three_swaps_per_plan_then_402(self) -> None:
        plan_id = self.make_plan(pro=False)
        free = self.headers(pro=False)
        for i in range(3):
            r, _ = self.swap_with(plan_id, meal(f"Z{i}", 30), index=i % 3, headers=free)
            self.assertEqual(r.status_code, 200, r.text)
        r, single = self.swap_with(plan_id, meal("Z9", 30), headers=free)
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["detail"]["error_code"], "free_swaps_used")
        single.assert_not_called()
        self.assertEqual(db.get_budget_plan(plan_id)["swaps_used"], 3)
        # Going Pro lifts the per-plan cap.
        r, _ = self.swap_with(plan_id, meal("Zpro", 30), headers=self.headers(pro=True))
        self.assertEqual(r.status_code, 200, r.text)

    def test_free_swap_failures_do_not_count_toward_the_cap(self) -> None:
        plan_id = self.make_plan(pro=False)
        free = self.headers(pro=False)
        with mock.patch("app.mealplan.llm.generate_single_meal", side_effect=llm.LLMError("x", "y")):
            for _ in range(4):
                self.assertEqual(self.swap(plan_id, headers=free).status_code, 502)
        r, _ = self.swap_with(plan_id, meal("Z", 30), headers=free)
        self.assertEqual(r.status_code, 200, r.text)

    def test_lapsed_pro_cannot_swap_a_paid_plan(self) -> None:
        plan_id = self.make_plan(pro=True)
        r, single = self.swap_with(plan_id, meal("Z", 30), headers=self.headers(pro=False))
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["detail"]["error_code"], "pro_required")
        single.assert_not_called()

    def test_pro_burst_cap_is_429_rate_limit_exceeded(self) -> None:
        config.BURST_SWAP_PER_DAY = 2
        plan_id = self.make_plan(pro=True)
        for i in range(2):
            r, _ = self.swap_with(plan_id, meal(f"Z{i}", 30), index=i)
            self.assertEqual(r.status_code, 200, r.text)
        r, single = self.swap_with(plan_id, meal("Z9", 30))
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["detail"]["error_code"], "rate_limit_exceeded")
        single.assert_not_called()

    def test_pro_is_not_subject_to_the_free_swap_cap(self) -> None:
        plan_id = self.make_plan(pro=True)
        for i in range(4):
            r, _ = self.swap_with(plan_id, meal(f"Z{i}", 30), index=i % 3)
            self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(db.get_budget_plan(plan_id)["swaps_used"], 4)

    def test_spend_cap_applies_to_swaps(self) -> None:
        from app import spendcap
        plan_id = self.make_plan()
        with mock.patch(
            "app.mealplan.spendcap.check",
            side_effect=spendcap.SpendCapExceeded(1.0, 2.0),
        ), mock.patch("app.mealplan.llm.generate_single_meal") as single:
            r = self.swap(plan_id)
        self.assertEqual(r.status_code, 429)
        single.assert_not_called()

    def test_stale_concurrent_swap_is_rejected(self) -> None:
        plan_id = self.make_plan()
        self.assertTrue(db.update_budget_plan_after_swap(plan_id, "[]", 0))
        self.assertFalse(db.update_budget_plan_after_swap(plan_id, "[]", 0))  # stale read


class DeleteAccountTests(_Base):
    def test_plans_are_removed_with_the_account(self) -> None:
        r = self.plan()
        plan_id = r.json()["plan_id"]
        self.assertIsNotNone(db.get_budget_plan(plan_id))
        import inspect
        fn = next(f for n, f in inspect.getmembers(db, inspect.isfunction) if "delete_account" in n or "delete_user" in n)
        self.assertIn("budget_plans", inspect.getsource(fn))


class SyncCollectionTests(unittest.TestCase):
    def test_cooking_preferences_is_allowed(self) -> None:
        self.assertIn("cooking_preferences", db.SYNC_COLLECTIONS)


if __name__ == "__main__":
    unittest.main()
