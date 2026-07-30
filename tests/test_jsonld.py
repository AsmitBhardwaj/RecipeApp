"""schema.org Recipe JSON-LD parsing/normalization (app/pipeline/jsonld.py).

Exercises the messy shapes seen in the wild: instructions as a string, as a
list of HowToStep objects, and as HowToSection groupings; @graph nesting with
@type as a list; ISO-8601 durations and recipeYield; and the completeness
contract (missing steps → None, so the orchestrator falls to the article path).

    python3 -m unittest tests.test_jsonld
"""
from __future__ import annotations

import unittest

from app.pipeline import jsonld


def _page(ld_json: str) -> str:
    return (
        "<html><head>"
        f'<script type="application/ld+json">{ld_json}</script>'
        "</head><body>ignored</body></html>"
    )


class JsonLdTests(unittest.TestCase):
    def test_howtostep_list_and_fields(self):
        ld = """
        {
          "@context": "https://schema.org",
          "@type": "Recipe",
          "name": "Simple Pancakes",
          "recipeIngredient": ["2 cups flour", "1 cup milk"],
          "recipeInstructions": [
            {"@type": "HowToStep", "text": "Mix the batter."},
            {"@type": "HowToStep", "text": "Cook on a griddle."}
          ],
          "recipeYield": "4 servings",
          "prepTime": "PT10M",
          "cookTime": "PT1H30M",
          "image": "https://img.example/pancakes.jpg"
        }
        """
        parsed = jsonld.parse_recipe_jsonld(_page(ld))
        self.assertIsNotNone(parsed)
        r = parsed.recipe
        self.assertEqual(r.title, "Simple Pancakes")
        self.assertEqual([i.name for i in r.ingredients], ["2 cups flour", "1 cup milk"])
        self.assertEqual([s.text for s in r.instructions], ["Mix the batter.", "Cook on a griddle."])
        self.assertEqual([s.step_number for s in r.instructions], [1, 2])
        self.assertEqual(r.servings.amount, 4.0)
        self.assertEqual(r.prep_time_minutes, 10.0)
        self.assertEqual(r.cook_time_minutes, 90.0)  # PT1H30M
        self.assertEqual(r.confidence.overall, 1.0)
        self.assertEqual(parsed.image_url, "https://img.example/pancakes.jpg")

    def test_string_instructions_split_on_newlines(self):
        ld = """
        {
          "@type": "Recipe",
          "name": "Toast",
          "recipeIngredient": ["1 slice bread"],
          "recipeInstructions": "Toast the bread.\\nButter it."
        }
        """
        parsed = jsonld.parse_recipe_jsonld(_page(ld))
        self.assertIsNotNone(parsed)
        self.assertEqual([s.text for s in parsed.recipe.instructions], ["Toast the bread.", "Butter it."])

    def test_howtosection_flattened_and_graph_typelist(self):
        # @graph wrapper, @type as a list, and HowToSection grouping.
        ld = """
        {
          "@context": "https://schema.org",
          "@graph": [
            {"@type": "WebPage", "name": "not a recipe"},
            {
              "@type": ["Recipe", "NewsArticle"],
              "name": "Layered Dip",
              "recipeIngredient": ["beans", "cheese"],
              "recipeInstructions": [
                {
                  "@type": "HowToSection",
                  "itemListElement": [
                    {"@type": "HowToStep", "text": "Spread the beans."},
                    {"@type": "HowToStep", "text": "Add cheese."}
                  ]
                }
              ],
              "image": {"@type": "ImageObject", "url": "https://img.example/dip.jpg"}
            }
          ]
        }
        """
        parsed = jsonld.parse_recipe_jsonld(_page(ld))
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.recipe.title, "Layered Dip")
        self.assertEqual([s.text for s in parsed.recipe.instructions], ["Spread the beans.", "Add cheese."])
        self.assertEqual(parsed.image_url, "https://img.example/dip.jpg")

    def test_image_as_list_takes_first(self):
        ld = """
        {
          "@type": "Recipe",
          "name": "X",
          "recipeIngredient": ["a"],
          "recipeInstructions": ["do it"],
          "image": ["https://img.example/1.jpg", "https://img.example/2.jpg"]
        }
        """
        parsed = jsonld.parse_recipe_jsonld(_page(ld))
        self.assertEqual(parsed.image_url, "https://img.example/1.jpg")

    def test_incomplete_missing_instructions_returns_none(self):
        # Ingredients but no steps → NOT structured; caller falls to article path.
        ld = """
        {
          "@type": "Recipe",
          "name": "Incomplete",
          "recipeIngredient": ["2 cups flour"]
        }
        """
        self.assertIsNone(jsonld.parse_recipe_jsonld(_page(ld)))

    def test_incomplete_missing_ingredients_returns_none(self):
        ld = """
        {
          "@type": "Recipe",
          "name": "Incomplete",
          "recipeInstructions": ["Do a thing."]
        }
        """
        self.assertIsNone(jsonld.parse_recipe_jsonld(_page(ld)))

    def test_no_jsonld_returns_none(self):
        self.assertIsNone(jsonld.parse_recipe_jsonld("<html><body>no ld here</body></html>"))

    def test_malformed_jsonld_is_skipped_not_raised(self):
        html = _page("{ this is : not json }")
        self.assertIsNone(jsonld.parse_recipe_jsonld(html))


if __name__ == "__main__":
    unittest.main()
