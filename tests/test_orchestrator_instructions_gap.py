"""Regression tests for the "ingredients present, instructions empty" gap fix
(orchestrator caption path — CLAUDE.md §5).

An ingredients-only caption reaches the caption-extraction path (which is
correctly forbidden from inventing steps), so it comes back with real
ingredients but zero instructions. The fix re-routes *that specific case* into
`generate_generic_recipe`, reusing the extracted ingredients, and marks the
result `generated`.

These tests stub the two LLM calls (no network, no OpenAI key) and the IO
around them (URL resolve, fetch, db, images), then drive the real
`process_job` so the actual routing branch is exercised. Run with:

    python3 -m unittest tests.test_orchestrator_instructions_gap
"""
from __future__ import annotations

import unittest
from unittest import mock

from app.models import (
    Confidence,
    Ingredient,
    Instruction,
    Job,
    LLMRecipe,
)
from app.pipeline import orchestrator
from app.pipeline.fetch import VideoMetadata
from app.pipeline.urls import ResolvedUrl


CAPTION = "Crispy Cheesy Beef Taquitos\n\nIngredients\n• Ground beef\n• Mozzarella"
VIDEO_ID = "instagram:DVBmx5kAsa2"


def _job() -> Job:
    return Job(
        job_id="job-1",
        user_id="user-1",
        url="https://www.instagram.com/reel/DVBmx5kAsa2/",
        created_at="2026-07-28T00:00:00+00:00",
    )


def _extracted(*, ingredients, instructions) -> LLMRecipe:
    return LLMRecipe(
        title="Crispy Cheesy Beef Taquitos",
        ingredients=ingredients,
        instructions=instructions,
        confidence=Confidence(
            overall=0.4,
            ingredients_complete=bool(ingredients),
            instructions_complete=bool(instructions),
            missing_fields=["servings", "instructions"] if not instructions else [],
        ),
    )


REAL_INGREDIENTS = [
    Ingredient(name="Ground beef"),
    Ingredient(quantity=2, unit="cup", name="Mozzarella", notes="grated"),
]

GENERATED_STEPS = [
    Instruction(step_number=1, text="Brown the beef with the spices."),
    Instruction(step_number=2, text="Fill tortillas, roll, and fry until crisp."),
]


class InstructionsGapTest(unittest.TestCase):
    def _run(self, extracted: LLMRecipe, generated: LLMRecipe | None = None):
        """Drive process_job with everything but the LLM/routing stubbed out.

        Returns (finished_job, saved_recipe, generate_mock).
        """
        resolved = ResolvedUrl(
            url="https://www.instagram.com/reel/DVBmx5kAsa2/",
            platform="instagram",
            video_id="DVBmx5kAsa2",
            canonical_video_id=VIDEO_ID,
        )
        meta = VideoMetadata(
            caption=CAPTION, thumbnail_url=None, video_id="DVBmx5kAsa2", title="Taquitos"
        )
        generate_mock = mock.MagicMock(return_value=generated)
        saved = {}

        def _capture_recipe(recipe):
            saved["recipe"] = recipe

        with mock.patch.object(orchestrator.urls, "resolve", return_value=resolved), \
             mock.patch.object(orchestrator.fetch, "fetch_instagram_metadata", return_value=meta), \
             mock.patch.object(orchestrator.signal, "has_recipe_signal", return_value=True), \
             mock.patch.object(orchestrator.llm, "extract_recipe", return_value=extracted), \
             mock.patch.object(orchestrator.llm, "generate_generic_recipe", generate_mock), \
             mock.patch.object(orchestrator.images, "resolve_image", return_value=(None, "none")), \
             mock.patch.object(orchestrator.db, "get_recipe_by_video_id", return_value=None), \
             mock.patch.object(orchestrator.db, "save_job"), \
             mock.patch.object(orchestrator.db, "save_user_recipe"), \
             mock.patch.object(orchestrator.db, "save_recipe", side_effect=_capture_recipe):
            job = orchestrator.process_job(_job())

        return job, saved.get("recipe"), generate_mock

    # --- branch fires: real ingredients + zero instructions -> generated ---- #

    def test_zero_instructions_reroutes_to_generator(self):
        extracted = _extracted(ingredients=REAL_INGREDIENTS, instructions=[])
        generated = LLMRecipe(title="ignored", instructions=GENERATED_STEPS)

        job, recipe, generate_mock = self._run(extracted, generated)

        # 1. generate_generic_recipe was called once, with the extracted
        #    ingredients handed in and the extracted title as the dish name.
        generate_mock.assert_called_once()
        dish_arg = generate_mock.call_args.args[0]
        self.assertEqual(dish_arg.dish_name, "Crispy Cheesy Beef Taquitos")
        self.assertEqual(
            generate_mock.call_args.kwargs["known_ingredients"], REAL_INGREDIENTS
        )

        # 2. The saved recipe is flagged generated, keeps the REAL ingredients,
        #    and carries the generated method.
        self.assertEqual(recipe.source_type, "generated")
        self.assertEqual(recipe.ingredients, REAL_INGREDIENTS)
        self.assertEqual(recipe.instructions, GENERATED_STEPS)

        # 3. Confidence reflects the mixed case.
        self.assertTrue(recipe.confidence.ingredients_complete)
        self.assertTrue(recipe.confidence.instructions_complete)
        self.assertNotIn("instructions", recipe.confidence.missing_fields)
        self.assertLessEqual(recipe.confidence.overall, 0.5)

        self.assertEqual(job.status, "complete")

    # --- branch skipped: caption already has steps -------------------------- #

    def test_partial_steps_are_not_rerouted(self):
        existing_steps = [Instruction(step_number=1, text="Mix and bake.")]
        extracted = _extracted(ingredients=REAL_INGREDIENTS, instructions=existing_steps)

        job, recipe, generate_mock = self._run(extracted)

        generate_mock.assert_not_called()
        self.assertEqual(recipe.source_type, "caption")
        self.assertEqual(recipe.instructions, existing_steps)
        self.assertEqual(job.status, "complete")

    # --- branch skipped: no ingredients either (RULE 7 empty recipe) -------- #

    def test_no_ingredients_and_no_instructions_stays_caption(self):
        extracted = _extracted(ingredients=[], instructions=[])

        job, recipe, generate_mock = self._run(extracted)

        # The fix only fires when ingredients are present; a genuinely empty
        # extraction must NOT be turned into a generated recipe.
        generate_mock.assert_not_called()
        self.assertEqual(recipe.source_type, "caption")
        self.assertEqual(recipe.instructions, [])

    # --- pure merge helper -------------------------------------------------- #

    def test_merge_keeps_ingredients_swaps_instructions(self):
        extracted = _extracted(ingredients=REAL_INGREDIENTS, instructions=[])
        generated = LLMRecipe(title="ignored", instructions=GENERATED_STEPS)

        merged = orchestrator._with_generated_instructions(extracted, generated)

        self.assertEqual(merged.title, extracted.title)
        self.assertEqual(merged.ingredients, REAL_INGREDIENTS)
        self.assertEqual(merged.instructions, GENERATED_STEPS)
        self.assertTrue(merged.confidence.ingredients_complete)
        self.assertTrue(merged.confidence.instructions_complete)
        self.assertNotIn("instructions", merged.confidence.missing_fields)
        self.assertIn("servings", merged.confidence.missing_fields)
        self.assertLessEqual(merged.confidence.overall, 0.5)


if __name__ == "__main__":
    unittest.main()
