"""Plan on a Budget endpoint (docs/budget-meal-planning.md).

`POST /v1/meal-plan/budget` — generation-first (v1): given a weekly budget,
household size, dietary preferences, and the user's on-hand (Kitchen) items, it
runs ONE budget/On-Hand-aware LLM generation and returns a set of recipes, each
tagged with an estimated per-recipe cost (baseline basket cost × the user's
regional multiplier) and a short health signal.

Gating & guards (this fans out LLM work, so cost is guarded hard):
  * Auth: `Depends(current_user)` — signed-in accounts only.
  * PRO: server-side check of the `X-Pro-Entitled` client claim — free users
    cannot call it at all (mirrors the client ProGate lock). Spoofable like the
    import-limit claim, but the client can't reach here without a token and the
    rate limiter still bounds abuse.
  * Budget floor: rejects a request below `household_size × MIN_BUDGET_PER_PERSON`
    (app/budget.py), independent of the client, with a clear error the client shows.
  * Rate-limited per account + IP, like /v1/jobs.

Plan results are transient — nothing new is persisted here except that each
generated recipe is written into the shared recipes cache (so a committed
meal-plan entry can hydrate its body later). Accepted recipes are committed into
the existing `meal_plan` collection client-side.
"""
from __future__ import annotations

import uuid
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from . import budget, config, db, ratelimit
from .auth.router import current_user
from .auth.service import User
from .models import CostEstimate, Recipe
from .pipeline import llm, regional_cost

router = APIRouter(prefix="/v1/meal-plan", tags=["meal-plan"])


# --------------------------------------------------------------------------- #
# Shapes
# --------------------------------------------------------------------------- #


class BudgetPlanRequest(BaseModel):
    budget: float
    currency: str = "USD"
    household_size: int = 2
    dietary_preferences: List[str] = Field(default_factory=list)
    # The user's on-hand (Kitchen) items — the client is On Hand's source of
    # truth (payloads are opaque to the server), so it sends the snapshot.
    pantry_items: List[str] = Field(default_factory=list)
    region: Optional[str] = None


class PlannedRecipe(BaseModel):
    recipe: Recipe
    estimated_cost: CostEstimate  # baseline × regional multiplier (per-user)
    health_signal: str = ""


class BudgetPlanResponse(BaseModel):
    recipes: List[PlannedRecipe]
    currency: str
    budget: float
    min_budget: int
    regional_multiplier: float


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #


def _is_pro(request: Request) -> bool:
    """The client's Pro claim (see app/main.py `_client_pro_claim`)."""
    return (request.headers.get("X-Pro-Entitled") or "").strip().lower() in ("1", "true", "yes")


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


# --------------------------------------------------------------------------- #
# Endpoint
# --------------------------------------------------------------------------- #


@router.post("/budget", response_model=BudgetPlanResponse)
def plan_on_a_budget(
    req: BudgetPlanRequest, request: Request, user: User = Depends(current_user)
) -> BudgetPlanResponse:
    # 1. Pro gate — free users can't call this at all.
    if not _is_pro(request):
        raise HTTPException(
            status_code=403,
            detail={
                "error_code": "pro_required",
                "message": "Plan on a Budget is a Platter Pro feature.",
            },
        )

    # 2. Rate limit (this fans out to LLM generation — guard cost).
    try:
        ratelimit.check(user.id, _client_ip(request))
    except ratelimit.RateLimitExceeded as exc:
        raise HTTPException(status_code=429, detail=str(exc))

    # 3. Budget floor — enforced server-side, independent of the client.
    minimum = budget.min_budget(req.household_size)
    if req.budget < minimum:
        raise HTTPException(
            status_code=400,
            detail={
                "error_code": "budget_below_minimum",
                "message": f"The minimum weekly budget for {req.household_size} people is ${minimum}.",
                "min_budget": minimum,
            },
        )

    # 4. Generate the week's recipes in one LLM call.
    try:
        generated = llm.generate_budget_plan(
            budget=req.budget,
            currency=req.currency,
            household_size=req.household_size,
            dietary_preferences=req.dietary_preferences,
            on_hand=req.pantry_items,
            count=config.BUDGET_PLAN_RECIPE_COUNT,
        )
    except llm.LLMError as exc:
        raise HTTPException(status_code=502, detail={"error_code": exc.code, "message": exc.message})

    # 5. Annotate, cache, and apply the regional multiplier per recipe.
    multiplier = regional_cost.multiplier_for(req.region)
    planned: List[PlannedRecipe] = []
    for item in generated:
        recipe_id = str(uuid.uuid4())
        recipe = Recipe(
            recipe_id=recipe_id,
            # Synthetic cache key (no source video). Keeps recipes.canonical_video_id
            # UNIQUE and lets a committed meal-plan entry hydrate this body later.
            canonical_video_id=f"budget:{recipe_id}",
            title=item.recipe.title or "Budget recipe",
            servings=item.recipe.servings,
            prep_time_minutes=item.recipe.prep_time_minutes,
            cook_time_minutes=item.recipe.cook_time_minutes,
            total_time_minutes=item.recipe.total_time_minutes,
            ingredients=item.recipe.ingredients,
            instructions=item.recipe.instructions,
            confidence=item.recipe.confidence,
            nutrition=item.recipe.nutrition,
            source_type="generated",
            image_url=None,
            image_source="none",
            baseline_cost_estimate=item.baseline_cost,
            health_signal=item.health_signal,
        )
        db.save_recipe(recipe)  # organically grows the annotated shared cache
        estimated = CostEstimate(
            amount=round(item.baseline_cost.amount * multiplier, 2),
            currency=req.currency,
            basis="llm-v1×regional",
        )
        planned.append(
            PlannedRecipe(recipe=recipe, estimated_cost=estimated, health_signal=item.health_signal)
        )

    return BudgetPlanResponse(
        recipes=planned,
        currency=req.currency,
        budget=req.budget,
        min_budget=minimum,
        regional_multiplier=multiplier,
    )
