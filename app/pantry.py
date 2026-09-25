"""Pantry-suggestion feature — "what can I make from what I have?" (PANTRY_SCOPE.md).

Primary path is **cache-search**: score every cached recipe by how much of it the
user's pantry covers (word-boundary matching on `normalized_name`, reusing
`ingredient_matching`), dedupe near-duplicate dishes, and rank. When cache-search
returns too few matches (< SPARSE_THRESHOLD), a **generation fallback** synthesizes
a few by-ingredients recipes, flagged `source_type="generated"` with nutrition
suppressed — the same trust treatment as the existing paste-fallback generated
recipes (CLAUDE.md §5), surfaced under a distinct "Suggested recipe" badge on iOS.

Layers:
  * Pure functions (`normalize_pantry`, `compute_match`, `passes_floor`,
    `find_matches`, `dedup`) — no db/LLM, unit-tested directly.
  * Generation (`generate_pantry_suggestions`) — reuses llm + the recipe cache.
  * `router` — POST /v1/pantry/suggestions, account-scoped like app/sync.py.

Cache-search uses the full-scan `db.all_recipes()` (option A). See PANTRY_SCOPE.md
§3a for the inverted-index path deferred to v1.1.
"""
from __future__ import annotations

import re
import uuid
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from . import burstlimit, db, llm_cost, spendcap
from .auth.router import current_user
from .auth.service import User
from .ingredient_matching import ingredients_match, normalize_ingredient_name
from .models import DishIdentification, Recipe
from .pipeline import images, llm

# --------------------------------------------------------------------------- #
# Tuning knobs (PANTRY_SCOPE.md §3, §6). Not load-bearing — safe to adjust.
# --------------------------------------------------------------------------- #

SPARSE_THRESHOLD = 2      # generate when cache matches are fewer than this
GENERATION_COUNT = 3      # how many dishes the fallback proposes
_DEFAULT_LIMIT = 20
_MAX_LIMIT = 50

# Floor: a recipe must clear at least one of these to be suggested at all, so a
# single "salt" overlap doesn't surface the whole cache (PANTRY_SCOPE.md §3b).
_MIN_HAVE_COUNT = 2
_MIN_COVERAGE = 0.3

# Dedup thresholds (PANTRY_SCOPE.md §3d).
_TITLE_SIM = 0.5          # title-token Jaccard
_INGREDIENT_SIM = 0.6     # ingredient-set Jaccard


# --------------------------------------------------------------------------- #
# Shapes
# --------------------------------------------------------------------------- #


class MatchInfo(BaseModel):
    """How a recipe lines up against the pantry. `have`/`missing` are the recipe's
    own (normalized) ingredients, split by whether the pantry covers them, so
    `have_count + len(missing) == total_count` always holds."""

    have: List[str]
    missing: List[str]
    have_count: int
    total_count: int
    coverage: float
    score: float


class Suggestion(BaseModel):
    recipe: Recipe
    match: MatchInfo


# --------------------------------------------------------------------------- #
# Pure matching / ranking / dedup
# --------------------------------------------------------------------------- #


def normalize_pantry(names: List[str]) -> List[str]:
    """Canonicalize + de-duplicate raw pantry names (order-preserving), dropping
    entries that normalize to empty. Same normalizer the recipe side uses, so the
    two compare like with like."""
    out: List[str] = []
    seen: set[str] = set()
    for raw in names:
        n = normalize_ingredient_name(raw)
        if n and n not in seen:
            seen.add(n)
            out.append(n)
    return out


def _recipe_ingredient_norms(recipe: Recipe) -> List[str]:
    """A recipe's ingredient names in normalized form, unique + non-empty. Falls
    back to normalizing `name` on the fly for pre-backfill cached recipes whose
    `normalized_name` is still null."""
    out: List[str] = []
    seen: set[str] = set()
    for ing in recipe.ingredients:
        n = (ing.normalized_name or normalize_ingredient_name(ing.name)).strip()
        if n and n not in seen:
            seen.add(n)
            out.append(n)
    return out


def compute_match(pantry_norm: List[str], recipe: Recipe) -> MatchInfo:
    """Score one recipe against the (already normalized) pantry. Always returns a
    MatchInfo — filtering by floor is a separate step so generated suggestions can
    carry match context regardless of coverage."""
    rnorms = _recipe_ingredient_norms(recipe)
    have = [rn for rn in rnorms if any(ingredients_match(p, rn) for p in pantry_norm)]
    have_set = set(have)
    missing = [rn for rn in rnorms if rn not in have_set]

    total = len(rnorms)
    have_count = len(have)
    coverage = have_count / total if total else 0.0
    # Blend: coverage, absolute overlap (capped), and extraction confidence, so
    # 2-ingredient recipes don't dominate on coverage alone (PANTRY_SCOPE.md §3c).
    score = (
        0.6 * coverage
        + 0.3 * min(have_count / 5, 1.0)
        + 0.1 * recipe.confidence.overall
    )
    return MatchInfo(
        have=have,
        missing=missing,
        have_count=have_count,
        total_count=total,
        coverage=round(coverage, 4),
        score=round(score, 4),
    )


def passes_floor(m: MatchInfo) -> bool:
    """Drop no-overlap and barely-there matches (PANTRY_SCOPE.md §3b)."""
    if m.have_count == 0:
        return False
    return m.have_count >= _MIN_HAVE_COUNT or m.coverage >= _MIN_COVERAGE


def _tokens(text: str) -> set[str]:
    return {t for t in re.split(r"\s+", text.lower().strip()) if t}


def _jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def _same_dish(a: Suggestion, b: Suggestion) -> bool:
    """Near-duplicate test: similar titles AND overlapping ingredient sets. Both
    must hold, so two different dishes that share a title word (e.g. "chicken")
    aren't merged (PANTRY_SCOPE.md §3d)."""
    title_sim = _jaccard(_tokens(a.recipe.title), _tokens(b.recipe.title))
    if title_sim < _TITLE_SIM:
        return False
    ing_sim = _jaccard(set(a.match.have + a.match.missing), set(b.match.have + b.match.missing))
    return ing_sim >= _INGREDIENT_SIM


def dedup(sorted_suggestions: List[Suggestion]) -> List[Suggestion]:
    """Greedy: keep the first (highest-ranked) representative of each dish cluster.
    Expects input already sorted best-first so the survivor is the best one."""
    kept: List[Suggestion] = []
    for s in sorted_suggestions:
        if any(_same_dish(s, k) for k in kept):
            continue
        kept.append(s)
    return kept


def _rank_key(s: Suggestion):
    # score, then absolute overlap, then fewest missing.
    return (s.match.score, s.match.have_count, -len(s.match.missing))


def find_matches(pantry_norm: List[str], recipes: List[Recipe], limit: int) -> List[Suggestion]:
    """Cache-search: match every recipe, keep those clearing the floor, rank,
    dedupe near-duplicate dishes, and take the top `limit`."""
    suggestions: List[Suggestion] = []
    for r in recipes:
        m = compute_match(pantry_norm, r)
        if m.total_count == 0 or not passes_floor(m):
            continue
        suggestions.append(Suggestion(recipe=r, match=m))

    suggestions.sort(key=_rank_key, reverse=True)
    suggestions = dedup(suggestions)
    return suggestions[:limit]


# --------------------------------------------------------------------------- #
# Generation fallback (LLM + cache). Only invoked when matches are sparse.
# --------------------------------------------------------------------------- #


def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return s or "dish"


def _generated_recipe_for_dish(dish: DishIdentification) -> Recipe:
    """Build (or reuse) a generated recipe for one proposed dish.

    Keyed in the shared cache under a synthetic `pantry-gen:<slug>` id so a
    repeated suggestion reuses the cached body instead of re-calling the LLM
    (the same idempotency guardrail the video pipeline relies on, CLAUDE.md §7).
    Nutrition is force-null: a generated recipe's macros would be computed off
    invented quantities — the exact rule orchestrator._finalize applies, mirrored
    here since suggestions don't run through that job chokepoint.
    """
    vid = f"pantry-gen:{_slug(dish.dish_name or '')}"
    cached = db.get_recipe_by_video_id(vid)
    if cached is not None:
        return cached

    llm_recipe = llm.generate_generic_recipe(dish)
    title = llm_recipe.title or dish.dish_name or "Suggested recipe"
    image_url, image_source = images.resolve_image(None, title)
    recipe = Recipe(
        recipe_id=str(uuid.uuid4()),
        canonical_video_id=vid,
        title=title,
        servings=llm_recipe.servings,
        prep_time_minutes=llm_recipe.prep_time_minutes,
        cook_time_minutes=llm_recipe.cook_time_minutes,
        total_time_minutes=llm_recipe.total_time_minutes,
        ingredients=llm_recipe.ingredients,
        instructions=llm_recipe.instructions,
        confidence=llm_recipe.confidence,
        nutrition=None,  # suppressed — generated (PANTRY_SCOPE.md §3e / §4)
        source_type="generated",
        image_url=image_url,
        image_source=image_source,  # type: ignore[arg-type]
    )
    db.save_recipe(recipe)  # also stamps normalized_name onto the ingredients
    # Re-read so the returned recipe carries the normalized_name the cache now
    # holds (save_recipe normalizes a copy, not the passed object).
    return db.get_recipe_by_video_id(vid) or recipe


def generate_pantry_suggestions(pantry_norm: List[str], limit: int) -> List[Suggestion]:
    """Fallback: propose a few dishes from the pantry and generate recipes for
    them. Each result carries its own pantry match context (no floor applied —
    these are offered precisely because cache-search came up short)."""
    dishes = llm.suggest_dishes_from_pantry(pantry_norm, GENERATION_COUNT)
    out: List[Suggestion] = []
    for dish in dishes:
        recipe = _generated_recipe_for_dish(dish)
        out.append(Suggestion(recipe=recipe, match=compute_match(pantry_norm, recipe)))
    return out[:limit]


# --------------------------------------------------------------------------- #
# Orchestration + API
# --------------------------------------------------------------------------- #


class SuggestionsRequest(BaseModel):
    limit: int = Field(_DEFAULT_LIMIT, ge=1, le=_MAX_LIMIT)
    # None -> read the user's synced pantry; an explicit list (incl. []) overrides.
    pantry_override: Optional[List[str]] = None
    allow_generation: bool = True


class SuggestionsResponse(BaseModel):
    matches: List[Suggestion]
    generated: List[Suggestion]
    pantry_used: List[str]
    counts: dict


def build_suggestions(
    user_id: str,
    *,
    limit: int = _DEFAULT_LIMIT,
    pantry_override: Optional[List[str]] = None,
    allow_generation: bool = True,
) -> SuggestionsResponse:
    """Top-level flow: resolve pantry → cache-search → (sparse?) generate."""
    names = pantry_override if pantry_override is not None else db.pantry_item_names(user_id)
    pantry_norm = normalize_pantry(names)
    if not pantry_norm:
        return SuggestionsResponse(
            matches=[], generated=[], pantry_used=[], counts={"cache": 0, "generated": 0}
        )

    matches = find_matches(pantry_norm, db.all_recipes(), limit)

    generated: List[Suggestion] = []
    if allow_generation and len(matches) < SPARSE_THRESHOLD:
        # Only this fallback fans out to the LLM (cache-search above makes no model
        # call), so the hard 30-day spend cap is checked HERE, not on the endpoint —
        # a cache-only search never spends and must never be blocked. Raises
        # SpendCapExceeded, which the router maps to 429; cache `matches` are still
        # computed above, but we fail the request rather than return a partial.
        spendcap.check(user_id)
        # Attribute its cost to this account under "pantry_suggestion".
        with llm_cost.track(user_id, "pantry_suggestion"):
            generated = generate_pantry_suggestions(pantry_norm, limit)

    return SuggestionsResponse(
        matches=matches,
        generated=generated,
        pantry_used=pantry_norm,
        counts={"cache": len(matches), "generated": len(generated)},
    )


router = APIRouter(prefix="/v1", tags=["pantry"])


@router.post("/pantry/suggestions", response_model=SuggestionsResponse)
def pantry_suggestions(
    req: SuggestionsRequest, user: User = Depends(current_user)
) -> SuggestionsResponse:
    # Per-account daily cap on this LLM-backed endpoint (the generation fallback
    # fans out to the model). Independent of the import/budget caps; 429 with the
    # distinct rate_limit_exceeded code.
    try:
        burstlimit.check_pantry(user.id)
    except burstlimit.BurstLimitExceeded as exc:
        raise HTTPException(
            status_code=429,
            detail={
                "error_code": exc.code,
                "message": "You've reached today's suggestion limit. Please try again tomorrow.",
                "limit": exc.limit,
                "window": exc.window_label,
            },
        )
    # NOTE: the hard 30-day spend cap is NOT enforced here — cache-search makes no
    # LLM call and must stay free. It is checked inside build_suggestions, only on
    # the generation-fallback path (the only branch that spends), surfaced as 429.
    try:
        return build_suggestions(
            user.id,
            limit=req.limit,
            pantry_override=req.pantry_override,
            allow_generation=req.allow_generation,
        )
    except spendcap.SpendCapExceeded as exc:
        raise HTTPException(
            status_code=429,
            detail={
                "error_code": exc.code,
                "message": "You've hit your recent usage limit. It frees up as your usage from the past 30 days ages off.",
                "limit": exc.limit,
                "window": exc.window_label,
            },
        )
