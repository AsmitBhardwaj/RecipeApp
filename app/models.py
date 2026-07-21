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


class Instruction(BaseModel):
    step_number: int
    text: str


class Confidence(BaseModel):
    overall: float = 0.0
    ingredients_complete: bool = False
    instructions_complete: bool = False
    missing_fields: List[str] = Field(default_factory=list)


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
    source_type: Literal["caption", "generated"]
    image_url: Optional[str] = None
    image_source: Literal["video_thumbnail", "stock_photo", "none"] = "none"

    # Nullable placeholders for future features (CLAUDE.md §8) — cheap to add
    # now so no schema migration is needed when transcription / nutrition land.
    transcript: Optional[str] = None
    nutrition: Optional[dict] = None


class Job(BaseModel):
    job_id: str
    user_id: str
    url: str
    canonical_video_id: Optional[str] = None
    platform: Optional[Literal["instagram", "tiktok"]] = None
    status: Literal["queued", "processing", "complete", "failed"] = "queued"
    # Explicit even though only "caption_only" exists now (CLAUDE.md §4).
    extraction_method: str = "caption_only"
    created_at: str
    recipe_id: Optional[str] = None
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
