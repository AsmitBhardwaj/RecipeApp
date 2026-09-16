"""Ingredient normalization + pantry matching (app/ingredient_matching.py) and
the write-time wiring in db.save_recipe.

Covers the two issues found in the cache-viability probe (the JSON-LD chickpeas
line normalizing cleanly; "egg" not matching inside "veggies"), a couple of
already-clean caption names (no regression), and the known/accepted limitation
that a bare pantry item like "pepper" matches both "black pepper" and "bell
pepper".

    python3 -m unittest tests.test_ingredient_matching
"""
from __future__ import annotations

import os
import tempfile
import unittest

from app import config, db
from app.ingredient_matching import ingredients_match, normalize_ingredient_name
from app.models import Ingredient, Recipe, Servings


class NormalizeTests(unittest.TestCase):
    def test_jsonld_chickpeas_line(self):
        # The real example from the probe: whole line lives in `name` (JSON-LD).
        self.assertEqual(
            normalize_ingredient_name("1½ cups cooked chickpeas (drained and rinsed)"),
            "cooked chickpeas",
        )

    def test_jsonld_tahini_line_with_footnote(self):
        # Unicode fraction + spelled unit + trailing "*" footnote marker.
        self.assertEqual(
            normalize_ingredient_name("⅓ cup smooth tahini*"),
            "smooth tahini",
        )

    def test_already_clean_caption_names_unchanged(self):
        # Caption/article extraction already splits qty/unit out, so `name` is a
        # bare ingredient — normalization must not mangle it.
        self.assertEqual(normalize_ingredient_name("chickpeas"), "chickpeas")
        self.assertEqual(normalize_ingredient_name("olive oil"), "olive oil")

    def test_range_and_trailing_clause(self):
        self.assertEqual(normalize_ingredient_name("1-2 cloves garlic"), "garlic")
        self.assertEqual(
            normalize_ingredient_name("2 tomatoes, diced"), "tomatoes"
        )

    def test_empty_input(self):
        self.assertEqual(normalize_ingredient_name(""), "")


class MatchTests(unittest.TestCase):
    def test_egg_does_not_match_inside_veggies(self):
        # The false positive found in the probe: substring matching would match
        # "egg" inside "veggies"; word-boundary matching must not.
        self.assertFalse(ingredients_match("egg", "veggies"))

    def test_chickpeas_matches_normalized_jsonld_name(self):
        # Pantry "chickpeas" against the stored/normalized chickpeas line.
        self.assertTrue(ingredients_match("chickpeas", "cooked chickpeas"))

    def test_pantry_item_is_normalized_before_matching(self):
        # A pantry entry the user typed with a quantity still matches.
        self.assertTrue(ingredients_match("2 cups chickpeas", "cooked chickpeas"))

    def test_known_limitation_bare_pepper_matches_both(self):
        # EXPECTED, not a bug: a bare "pepper" is a whole word in both, so it
        # matches both. Documenting the limitation, not fixing it.
        self.assertTrue(ingredients_match("pepper", "black pepper"))
        self.assertTrue(ingredients_match("pepper", "bell pepper"))

    def test_empty_pantry_item_matches_nothing(self):
        self.assertFalse(ingredients_match("", "cooked chickpeas"))


class SaveRecipeWiringTests(unittest.TestCase):
    """db.save_recipe must populate normalized_name for every source type."""

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

    def test_structured_recipe_gets_normalized_names_on_save(self):
        # JSON-LD/structured: whole line in `name`, no split — the hard case.
        recipe = Recipe(
            recipe_id="r1",
            canonical_video_id="vid1",
            title="Hummus",
            servings=Servings(),
            ingredients=[
                Ingredient(name="1½ cups cooked chickpeas (drained and rinsed)"),
                Ingredient(name="⅓ cup smooth tahini*"),
            ],
            source_type="structured",
        )
        db.save_recipe(recipe)

        stored = db.get_recipe("r1")
        self.assertIsNotNone(stored)
        # `name` is preserved verbatim for display...
        self.assertEqual(
            stored.ingredients[0].name, "1½ cups cooked chickpeas (drained and rinsed)"
        )
        # ...while normalized_name is populated for matching.
        self.assertEqual(stored.ingredients[0].normalized_name, "cooked chickpeas")
        self.assertEqual(stored.ingredients[1].normalized_name, "smooth tahini")

    def test_caption_recipe_normalized_name_matches_bare_name(self):
        recipe = Recipe(
            recipe_id="r2",
            canonical_video_id="vid2",
            title="Salad",
            servings=Servings(),
            ingredients=[Ingredient(quantity=2.0, unit="cup", name="chickpeas")],
            source_type="caption",
        )
        db.save_recipe(recipe)
        stored = db.get_recipe("r2")
        self.assertEqual(stored.ingredients[0].normalized_name, "chickpeas")


if __name__ == "__main__":
    unittest.main()
