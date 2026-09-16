"""Pantry-suggestion tests (PANTRY_SCOPE.md Pass 1).

Three layers:
  * Pure matching/ranking/dedup — no db, no LLM.
  * Generation fallback — LLM + images stubbed, real temp db (idempotent caching,
    nutrition suppression).
  * The POST /v1/pantry/suggestions endpoint — auth gating, cache-search over a
    seeded cache + synced pantry, override, and the sparse -> generation trigger.
"""
from __future__ import annotations

import os
import tempfile
import unittest
from unittest import mock

from fastapi.testclient import TestClient

from app import config, db, pantry
from app.main import app
from app.models import (
    Confidence,
    DishIdentification,
    Ingredient,
    LLMRecipe,
    Recipe,
)


def _recipe(title, names, *, rid=None, vid=None, conf=0.8, source="caption") -> Recipe:
    return Recipe(
        recipe_id=rid or title,
        canonical_video_id=vid or title,
        title=title,
        ingredients=[Ingredient(name=n) for n in names],
        confidence=Confidence(overall=conf),
        source_type=source,
    )


CARBONARA = _recipe("Spaghetti Carbonara", ["egg", "spaghetti", "bacon", "parmesan", "black pepper"])
OMELETTE = _recipe("Cheese Omelette", ["egg", "butter", "cheddar cheese"])


# --------------------------------------------------------------------------- #
# Pure matching / ranking / dedup
# --------------------------------------------------------------------------- #


class PureMatchingTests(unittest.TestCase):
    def test_normalize_pantry_dedups_and_canonicalizes(self):
        # Leading qty/unit stripped, lowercased, de-duplicated, empties dropped.
        got = pantry.normalize_pantry(["Eggs", "eggs", "1 cup Flour", "   ", "Flour"])
        self.assertEqual(got, ["eggs", "flour"])

    def test_compute_match_counts_and_coverage(self):
        m = pantry.compute_match(["egg", "spaghetti", "bacon"], CARBONARA)
        self.assertEqual(m.have_count, 3)
        self.assertEqual(m.total_count, 5)
        self.assertAlmostEqual(m.coverage, 0.6, places=3)
        self.assertEqual(sorted(m.missing), ["black pepper", "parmesan"])
        # have + missing partition the recipe's ingredients.
        self.assertEqual(m.have_count + len(m.missing), m.total_count)

    def test_word_boundary_no_false_positive(self):
        # "egg" must NOT match inside "veggies" (the regression the matcher fixes).
        veg = _recipe("Veggie Stir Fry", ["veggies", "soy sauce", "rice"])
        m = pantry.compute_match(["egg"], veg)
        self.assertEqual(m.have_count, 0)
        self.assertFalse(pantry.passes_floor(m))

    def test_floor_drops_single_low_coverage_match(self):
        big = _recipe("Everything Bowl", [f"item{i}" for i in range(10)] + ["egg"])
        m = pantry.compute_match(["egg"], big)
        self.assertEqual(m.have_count, 1)
        self.assertLess(m.coverage, 0.3)
        self.assertFalse(pantry.passes_floor(m))

    def test_floor_keeps_single_high_coverage_match(self):
        m = pantry.compute_match(["egg"], OMELETTE)  # 1 of 3 -> coverage .333
        self.assertEqual(m.have_count, 1)
        self.assertTrue(pantry.passes_floor(m))

    def test_find_matches_ranks_higher_coverage_first(self):
        results = pantry.find_matches(["egg", "spaghetti", "bacon"], [OMELETTE, CARBONARA], limit=10)
        self.assertEqual([s.recipe.title for s in results], ["Spaghetti Carbonara", "Cheese Omelette"])

    def test_find_matches_respects_limit(self):
        results = pantry.find_matches(["egg", "spaghetti", "bacon"], [OMELETTE, CARBONARA], limit=1)
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0].recipe.title, "Spaghetti Carbonara")

    def test_dedup_collapses_near_duplicate_dishes(self):
        # Same dish from two source videos: same title tokens + high ingredient overlap.
        c2 = _recipe(
            "Spaghetti Carbonara",
            ["egg", "spaghetti", "pancetta", "parmesan", "black pepper"],
            rid="carb2", vid="carb2", conf=0.5,
        )
        results = pantry.find_matches(["egg", "spaghetti", "bacon"], [CARBONARA, c2], limit=10)
        titles = [s.recipe.title for s in results]
        self.assertEqual(titles.count("Spaghetti Carbonara"), 1)
        # The higher-confidence one survives.
        self.assertEqual(results[0].recipe.recipe_id, "Spaghetti Carbonara")

    def test_distinct_dishes_sharing_a_title_word_not_merged(self):
        a = _recipe("Chicken Curry", ["chicken", "curry paste", "coconut milk", "onion"])
        b = _recipe("Chicken Salad", ["chicken", "lettuce", "mayo", "celery"])
        results = pantry.find_matches(["chicken", "onion", "curry paste", "mayo", "lettuce"], [a, b], limit=10)
        self.assertEqual(len(results), 2)  # different ingredient sets -> not deduped


# --------------------------------------------------------------------------- #
# Generation fallback
# --------------------------------------------------------------------------- #


class GenerationTests(unittest.TestCase):
    def setUp(self):
        self._orig_db = config.DB_PATH
        fd, self._path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        config.DB_PATH = self._path
        db.init_db()

    def tearDown(self):
        config.DB_PATH = self._orig_db
        try:
            os.remove(self._path)
        except OSError:
            pass

    def _generated_llm_recipe(self) -> LLMRecipe:
        from app.models import Instruction, Nutrition, Servings

        return LLMRecipe(
            title="Chickpea Curry",
            servings=Servings(amount=2, unit="servings"),
            ingredients=[Ingredient(quantity=1, unit="can", name="chickpeas"), Ingredient(name="onion")],
            instructions=[Instruction(step_number=1, text="Simmer everything.")],
            confidence=Confidence(overall=0.6),
            # Model returns nutrition; the generated path must strip it.
            nutrition=Nutrition(calories=400, basis="per_recipe", source="estimated"),
        )

    def test_generation_flags_generated_suppresses_nutrition_and_caches(self):
        dishes = [DishIdentification(dish_name="Chickpea Curry", confidence=0.7)]
        gen_mock = mock.MagicMock(return_value=self._generated_llm_recipe())
        with mock.patch.object(pantry.llm, "suggest_dishes_from_pantry", return_value=dishes), \
             mock.patch.object(pantry.llm, "generate_generic_recipe", gen_mock), \
             mock.patch.object(pantry.images, "resolve_image", return_value=(None, "none")):
            first = pantry.generate_pantry_suggestions(["chickpeas", "onion"], limit=10)

            self.assertEqual(len(first), 1)
            recipe = first[0].recipe
            self.assertEqual(recipe.source_type, "generated")
            self.assertIsNone(recipe.nutrition)  # suppressed
            self.assertEqual(recipe.canonical_video_id, "pantry-gen:chickpea-curry")
            # Cached, and normalized_name was stamped at save time.
            self.assertIsNotNone(db.get_recipe_by_video_id("pantry-gen:chickpea-curry"))
            self.assertTrue(all(i.normalized_name for i in recipe.ingredients))
            # Match context is attached.
            self.assertEqual(first[0].match.have_count, 2)

            # Second call reuses the cache — no second LLM generation.
            second = pantry.generate_pantry_suggestions(["chickpeas", "onion"], limit=10)
            gen_mock.assert_called_once()
            self.assertEqual(second[0].recipe.recipe_id, recipe.recipe_id)


# --------------------------------------------------------------------------- #
# Endpoint
# --------------------------------------------------------------------------- #


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self._orig_db = config.DB_PATH
        fd, self._path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        config.DB_PATH = self._path
        db.init_db()
        self.client = TestClient(app)
        r = self.client.post("/auth/register", json={"email": "pantry@user.com", "password": "supersecret1"})
        self.assertEqual(r.status_code, 200, r.text)
        self.auth = {"Authorization": f"Bearer {r.json()['access_token']}"}

    def tearDown(self):
        config.DB_PATH = self._orig_db
        try:
            os.remove(self._path)
        except OSError:
            pass

    def _push_pantry(self, *names):
        changes = [
            {"collection": "pantry_items", "item_id": n, "updated_at": 1, "payload": f'{{"name":"{n}"}}'}
            for n in names
        ]
        r = self.client.post("/v1/sync/push", json={"changes": changes}, headers=self.auth)
        self.assertEqual(r.status_code, 200, r.text)

    def _suggest(self, **body):
        return self.client.post("/v1/pantry/suggestions", json=body, headers=self.auth)

    def test_requires_auth(self):
        self.assertEqual(self.client.post("/v1/pantry/suggestions", json={}).status_code, 401)

    def test_cache_search_uses_synced_pantry(self):
        db.save_recipe(CARBONARA)
        db.save_recipe(OMELETTE)
        self._push_pantry("egg", "spaghetti", "bacon")

        # allow_generation off: isolate cache-search.
        r = self._suggest(allow_generation=False)
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        titles = [s["recipe"]["title"] for s in body["matches"]]
        self.assertIn("Spaghetti Carbonara", titles)
        self.assertEqual(body["counts"]["cache"], len(body["matches"]))
        self.assertEqual(sorted(body["pantry_used"]), ["bacon", "egg", "spaghetti"])

    def test_pantry_override_bypasses_synced_pantry(self):
        db.save_recipe(CARBONARA)
        # No pantry synced; override supplies it.
        r = self._suggest(pantry_override=["egg", "spaghetti", "bacon"], allow_generation=False)
        self.assertEqual(r.status_code, 200, r.text)
        self.assertTrue(any(s["recipe"]["title"] == "Spaghetti Carbonara" for s in r.json()["matches"]))

    def test_empty_pantry_returns_empty(self):
        r = self._suggest(pantry_override=[])
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        self.assertEqual(body["matches"], [])
        self.assertEqual(body["generated"], [])

    def test_no_generation_when_matches_plentiful(self):
        db.save_recipe(CARBONARA)
        db.save_recipe(OMELETTE)  # two matches -> >= SPARSE_THRESHOLD
        with mock.patch.object(pantry.llm, "suggest_dishes_from_pantry") as gen:
            r = self._suggest(pantry_override=["egg", "spaghetti", "bacon"])
            self.assertEqual(r.status_code, 200, r.text)
            gen.assert_not_called()
            self.assertEqual(r.json()["generated"], [])

    def test_sparse_matches_trigger_generation(self):
        from app.models import Instruction, Servings

        # Empty cache -> zero matches -> generation fires.
        dishes = [DishIdentification(dish_name="Egg Fried Rice", confidence=0.7)]
        gen_recipe = LLMRecipe(
            title="Egg Fried Rice",
            servings=Servings(amount=2, unit="servings"),
            ingredients=[Ingredient(name="egg"), Ingredient(name="rice")],
            instructions=[Instruction(step_number=1, text="Fry it.")],
            confidence=Confidence(overall=0.6),
        )
        with mock.patch.object(pantry.llm, "suggest_dishes_from_pantry", return_value=dishes), \
             mock.patch.object(pantry.llm, "generate_generic_recipe", return_value=gen_recipe), \
             mock.patch.object(pantry.images, "resolve_image", return_value=(None, "none")):
            r = self._suggest(pantry_override=["egg", "rice"])
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        self.assertEqual(body["matches"], [])
        self.assertEqual(len(body["generated"]), 1)
        gen = body["generated"][0]["recipe"]
        self.assertEqual(gen["source_type"], "generated")
        self.assertIsNone(gen["nutrition"])  # suppressed on the wire too
        self.assertEqual(body["counts"]["generated"], 1)


if __name__ == "__main__":
    unittest.main()
