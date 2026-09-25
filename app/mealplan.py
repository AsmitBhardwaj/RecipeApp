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

import logging
import uuid
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from . import budget, burstlimit, config, db, llm_cost, ratelimit, spendcap
from .auth.router import current_user
from .auth.service import User
from .models import CostEstimate, Recipe
from .pipeline import llm, regional_cost

router = APIRouter(prefix="/v1/meal-plan", tags=["meal-plan"])

_log = logging.getLogger("uvicorn.error")


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
    # Location signal for the regional cost multiplier (docs §3.4): an ISO 3166-1
    # alpha-2 country code + an area type (city/suburb/rural). Either may be unset,
    # in which case that part falls back to its 1.0 default.
    country: Optional[str] = None
    area_type: Optional[str] = None


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


def _baseline_total(plan: List["llm.BudgetPlanRecipeLLM"]) -> float:
    """The plan's cost in location-independent (baseline) space — the sum of the
    LLM's per-recipe baseline estimates. This is the space the prompt targets."""
    return sum(item.baseline_cost.amount for item in plan)


def _adjusted_total(plan: List["llm.BudgetPlanRecipeLLM"], multiplier: float) -> float:
    """The plan's regionally-adjusted total — what the user actually sees, and what
    the budget fit-check compares against `req.budget`."""
    return round(_baseline_total(plan) * multiplier, 2)


def _pick_plan(
    first: List["llm.BudgetPlanRecipeLLM"],
    second: List["llm.BudgetPlanRecipeLLM"],
    multiplier: float,
    budget_cap: float,
) -> List["llm.BudgetPlanRecipeLLM"]:
    """Best-effort selection between a plan and its corrective retry: prefer the
    larger adjusted total that does NOT exceed the budget (use as much of the
    budget as possible without overshooting). If both exceed, take the smaller."""
    a, b = _adjusted_total(first, multiplier), _adjusted_total(second, multiplier)
    a_ok, b_ok = a <= budget_cap, b <= budget_cap
    if a_ok and b_ok:
        return first if a >= b else second
    if a_ok:
        return first
    if b_ok:
        return second
    return first if a <= b else second


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

    # 2. Rate limit (this fans out to LLM generation — guard cost). The generic
    #    per-user/IP limiter, plus a per-account daily cap on this specific LLM
    #    endpoint (independent of the import caps).
    try:
        ratelimit.check(user.id, _client_ip(request))
    except ratelimit.RateLimitExceeded as exc:
        raise HTTPException(status_code=429, detail=str(exc))
    try:
        burstlimit.check_budget_plan(user.id)
    except burstlimit.BurstLimitExceeded as exc:
        raise HTTPException(
            status_code=429,
            detail={
                "error_code": exc.code,
                "message": "You've reached today's budget-plan limit. Please try again tomorrow.",
                "limit": exc.limit,
                "window": exc.window_label,
            },
        )
    # Hard per-account 30-day dollar cap (app/spendcap.py) — the enforcing backstop
    # above the count caps; blocks once trailing-30-day estimated spend is over it.
    try:
        spendcap.check(user.id)
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

    # 3. Resolve the regional multiplier FIRST, so we can hand the LLM a budget in
    #    its own location-independent (baseline) space: user budget ÷ multiplier.
    #    Without this, a user in a 1.3× region was silently given a target 1.3× too
    #    high (the recipe costs get multiplied afterward). Guard divide-by-zero
    #    (multipliers are always > 0 today, but never trust that at a divide).
    multiplier = regional_cost.multiplier_for(req.country, req.area_type)
    baseline_budget = req.budget / multiplier if multiplier > 0 else req.budget

    # 3b. Budget bounds — modeled in baseline space (app/budget.py), enforced
    #     server-side both ways. Reject (never silently clamp) too-low and too-high
    #     requests; report the threshold back in the user's LOCAL units (× the
    #     multiplier) so the message matches the number they typed.
    def _to_local(baseline_amount: float) -> int:
        return int(round((baseline_amount * multiplier) / 5) * 5)

    min_baseline = budget.min_budget(req.household_size)
    max_baseline = budget.max_budget(req.household_size)
    min_local, max_local = _to_local(min_baseline), _to_local(max_baseline)
    if baseline_budget < min_baseline:
        raise HTTPException(
            status_code=400,
            detail={
                "error_code": "budget_below_minimum",
                "message": f"The minimum weekly budget for {req.household_size} people is ${min_local}.",
                "min_budget": min_local,
            },
        )
    if baseline_budget > max_baseline:
        raise HTTPException(
            status_code=400,
            detail={
                "error_code": "budget_above_maximum",
                "message": f"The maximum weekly budget for {req.household_size} people is ${max_local}.",
                "max_budget": max_local,
            },
        )

    # 4. Decide the recipe count (cut below 7 only when the budget is too small to
    #    fill a week without undershooting) and whether to steer toward richer
    #    recipes (a generous budget goes into richness, not more dishes).
    floor_amount = req.budget * llm.BUDGET_TARGET_FLOOR_FRAC
    recipe_count = budget.target_recipe_count(baseline_budget, req.household_size)
    steer_rich = budget.wants_rich(baseline_budget, req.household_size)

    def _generate(prior_total: Optional[float] = None):
        return llm.generate_budget_plan(
            budget=baseline_budget,
            currency=req.currency,
            household_size=req.household_size,
            dietary_preferences=req.dietary_preferences,
            on_hand=req.pantry_items,
            count=recipe_count,
            prior_total=prior_total,
            rich=steer_rich,
        )

    # 5. Generate the week's recipes. If the plan lands under the target band
    #    (< floor), run ONE bounded corrective pass asking for a fuller plan, then
    #    keep whichever fits the budget best. Ship best-effort either way.
    # Attribute both the initial generation and any corrective pass to this
    # account under call_type "budget_plan" (internal cost tracking).
    try:
        with llm_cost.track(user.id, "budget_plan"):
            generated = _generate()
            if _adjusted_total(generated, multiplier) < floor_amount:
                try:
                    retried = _generate(prior_total=round(_baseline_total(generated), 2))
                    generated = _pick_plan(generated, retried, multiplier, req.budget)
                except llm.LLMError:
                    # Corrective pass failed — keep the first plan (best-effort).
                    pass
    except llm.LLMError as exc:
        raise HTTPException(status_code=502, detail={"error_code": exc.code, "message": exc.message})

    # Best-effort: if we still couldn't reach the band, ship it but log the miss
    # (budget, actual, region) so we can see how often the retry doesn't fix it.
    final_total = _adjusted_total(generated, multiplier)
    if final_total < floor_amount:
        _log.warning(
            "budget-plan under target after retry: budget=%.2f actual=%.2f frac=%.2f "
            "country=%s area=%s multiplier=%.2f",
            req.budget, final_total,
            (final_total / req.budget if req.budget else 0.0),
            req.country, req.area_type, multiplier,
        )

    # 6. Annotate, cache, and apply the regional multiplier — only for the SELECTED
    #    plan, so a discarded corrective attempt never pollutes the shared cache.
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
        min_budget=min_local,
        regional_multiplier=multiplier,
    )
