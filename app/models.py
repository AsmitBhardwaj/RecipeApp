"""Pydantic models mirroring CLAUDE.md §4 (Job, Recipe, user-recipe join).

Two families of models live here:

  * Storage/API models: `Job`, `Recipe`, `UserRecipe` — the persisted shapes.
  * LLM-output models: `LLMRecipe`, `DishIdentification` — what the model is
    asked to return and what we validate its raw JSON against (CLAUDE.md §5).

The LLM only produces the recipe *content*; the orchestrator stamps on the
identity/image/source fields to build a full `Recipe`.
"""
from __future__ import annotations

from typing import List, Literal, Optional

from pydantic import BaseModel, Field

# --------------------------------------------------------------------------- #
# Shared sub-structures
# --------------------------------------------------------------------------- #


class Servings(BaseModel):
    amount: Optional[float] = None
    unit: Optional[str] = None


class Ingredient(BaseModel):
    quantity: Optional[float] = None
    unit: Optional[str] = None
    name: str
    notes: Optional[str] = None
    # Canonical form of `name` for pantry/ingredient matching — lowercased, with
    # leading quantities/units, parentheticals, and trailing comma-clauses
    # stripped (see app/ingredient_matching.normalize_ingredient_name). `name`
    # stays verbatim for display; this is the field matching reads. Populated at
    # write time for every source type (app/db.save_recipe), so it is derived,
    # never author-supplied. Nullable + additive: lives in the recipes.data JSON
    # blob (no migration), and pre-feature cached recipes decode it as null until
    # the one-time backfill fills them in.
    normalized_name: Optional[str] = None


class Instruction(BaseModel):
    step_number: int
    text: str
    # Per-step cooking duration in seconds when the step states/implies one
    # ("bake for 20 minutes" -> 1200); null when absent or ambiguous. Powers
    # Cook Mode's auto-detected step timers. Nullable + additive: it lives in the
    # recipes.data JSON blob, so no migration, and pre-Cook-Mode recipes decode
    # it as null. The client falls back to regex on the step text when null.
    duration_seconds: Optional[int] = None


class Confidence(BaseModel):
    overall: float = 0.0
    ingredients_complete: bool = False
    instructions_complete: bool = False
    # KNOWN ISSUE (tracked, not fixed): this list is the LLM's own self-report and
    # is not always consistent with the actual populated fields. Observed during
    # live nutrition testing: a recipe came back with `servings` listed here as
    # missing even though `servings.amount` was in fact populated (2.0). Nothing
    # currently depends on missing_fields being accurate (it's advisory only), so
    # this is intentionally left as-is — but anything that later drives real logic
    # off missing_fields (e.g. a UI "incomplete recipe" prompt) must not trust it
    # blindly; reconcile it against the actual fields first.
    missing_fields: List[str] = Field(default_factory=list)


class CostEstimate(BaseModel):
    """A labeled, location-independent cost estimate for a recipe (Plan on a
    Budget — docs/budget-meal-planning.md §3.1/§3.4). `amount` is a rough basket
    cost; the per-user displayed cost is `amount × regional_multiplier`, computed
    at plan time. Always an ESTIMATE, never store-accurate."""

    amount: float
    currency: str = "USD"
    basis: str = "llm-v1"  # provenance tag so the estimate's origin is legible


class Nutrition(BaseModel):
    """Rough nutrition for a recipe (CLAUDE.md §8 / NUTRIENT_SCOPE.md).

    Produced in the SAME extraction LLM call, never a second round-trip. Two
    honesty markers travel with the numbers so downstream code/UI knows exactly
    what it's showing:

      * `basis`  — "per_serving" only when the recipe's serving count is known
        and usable; "per_recipe" (whole-recipe totals) otherwise. We never guess
        a serving count just to force a per-serving number.
      * `source` — "creator_stated" when the caption/source already gave macros
        (extracted verbatim); "estimated" when derived from ingredient
        quantities. Estimation is the ONE place the extractor may compute rather
        than only copy — but it must not invent ingredient quantities to do so.

    The whole object is optional on the recipe (nutrition is null when the source
    lacks enough usable ingredient quantities to estimate). The macro numbers are
    themselves optional so a partial estimate (e.g. calories but not fat) is
    representable rather than forcing a fabricated value.
    """

    calories: Optional[float] = None
    protein_g: Optional[float] = None
    carbs_g: Optional[float] = None
    fat_g: Optional[float] = None
    basis: Literal["per_serving", "per_recipe"]
    source: Literal["estimated", "creator_stated"]


# --------------------------------------------------------------------------- #
# LLM output models (validated against raw model JSON — CLAUDE.md §5)
# --------------------------------------------------------------------------- #


class LLMRecipe(BaseModel):
    """The recipe *content* the LLM returns. No identity/image fields — the
    orchestrator adds those. `source_type` is set server-side, not trusted
    from the model."""

    title: str
    servings: Servings = Field(default_factory=Servings)
    prep_time_minutes: Optional[float] = None
    cook_time_minutes: Optional[float] = None
    total_time_minutes: Optional[float] = None
    ingredients: List[Ingredient] = Field(default_factory=list)
    instructions: List[Instruction] = Field(default_factory=list)
    confidence: Confidence = Field(default_factory=Confidence)
    # Rough nutrition estimated (or extracted verbatim) in this same call; null
    # when the source lacks enough usable ingredient quantities. See Nutrition.
    nutrition: Optional[Nutrition] = None


class DishIdentification(BaseModel):
    """Tier-4 fallback step 1 output (CLAUDE.md §5)."""

    dish_name: Optional[str] = None
    cuisine: Optional[str] = None
    confidence: float = 0.0
    distinguishing_details: List[str] = Field(default_factory=list)


# --------------------------------------------------------------------------- #
# Persisted / API models
# --------------------------------------------------------------------------- #


class Recipe(BaseModel):
    recipe_id: str
    canonical_video_id: str
    title: str
    servings: Servings = Field(default_factory=Servings)
    prep_time_minutes: Optional[float] = None
    cook_time_minutes: Optional[float] = None
    total_time_minutes: Optional[float] = None
    ingredients: List[Ingredient] = Field(default_factory=list)
    instructions: List[Instruction] = Field(default_factory=list)
    confidence: Confidence = Field(default_factory=Confidence)
    # "caption"/"generated" = video tiers; "structured" = schema.org JSON-LD
    # (ground truth, no LLM); "article" = LLM-extracted from blog article text.
    source_type: Literal["caption", "generated", "structured", "article"]
    image_url: Optional[str] = None
    # "web_image" = image pulled from the recipe page (JSON-LD image / og:image).
    image_source: Literal["video_thumbnail", "stock_photo", "web_image", "none"] = "none"

    # Nullable placeholder for a future feature (CLAUDE.md §8) — cheap to add now
    # so no schema migration is needed when transcription lands.
    transcript: Optional[str] = None
    # Rough per-recipe nutrition (NUTRIENT_SCOPE.md). Lives in the shared recipe
    # cache (this recipe row is keyed by canonical_video_id), so it is computed
    # once per recipe and reused across every user who saves that video — never
    # per user. Null when not estimable. Stored in the `data` JSON blob, so no
    # migration: pre-nutrition cached recipes decode it as null.
    nutrition: Optional[Nutrition] = None

    # Plan on a Budget annotations (docs/budget-meal-planning.md §3.1). Populated
    # at generation time for budget-plan recipes; null for every other recipe.
    # Additive + nullable → live in the `data` JSON blob, no migration.
    #   baseline_cost_estimate — location-independent basket cost (see CostEstimate).
    #   health_signal          — a short human string, e.g. "High protein, low sugar".
    baseline_cost_estimate: Optional[CostEstimate] = None
    health_signal: Optional[str] = None


class Job(BaseModel):
    job_id: str
    user_id: str
    url: str
    canonical_video_id: Optional[str] = None
    platform: Optional[Literal["instagram", "tiktok", "web"]] = None
    status: Literal["queued", "processing", "complete", "failed"] = "queued"
    # Explicit even though only "caption_only" exists now (CLAUDE.md §4).
    extraction_method: str = "caption_only"
    created_at: str
    recipe_id: Optional[str] = None
    # Verified account id (JWT `sub`) when the import was submitted signed-in;
    # None for anonymous/legacy submissions. Distinct from `user_id`, which is the
    # spoofable per-device X-User-Id. This is the key the free-import limit counts
    # against (app/importlimit.py) so the count is per account, across devices and
    # the Share Extension. Nullable + additive: lives in the jobs.data JSON blob,
    # so no migration — pre-feature jobs decode it as null.
    account_id: Optional[str] = None
    # Not in CLAUDE.md §4 — added so failures surface as a clear state instead
    # of an exception. `error_code` is a stable machine string; `error` is the
    # human-readable detail.
    error_code: Optional[str] = None
    error: Optional[str] = None


class UserRecipe(BaseModel):
    """Per-user personalization, kept separate from the shared/cached recipe
    (CLAUDE.md §4). sort_key exists as a bare field only — no ordering logic."""

    user_id: str
    recipe_id: str
    custom_name: Optional[str] = None
    sort_key: str = ""
    saved_at: str
