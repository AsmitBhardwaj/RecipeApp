"""Plan on a Budget endpoints (docs/budget-meal-planning.md).

`POST /v1/meal-plan/budget` — generation-first: given a weekly budget, household
size, dietary preferences, cooking appliances/moods, and the user's on-hand
(Kitchen) items, it runs ONE budget/On-Hand-aware LLM generation and returns a set
of recipes, each tagged with an estimated per-recipe cost (baseline basket cost ×
the user's multiplier) and a short health signal.

`POST /v1/meal-plan/budget/{plan_id}/swap` — replace ONE dinner in a stored plan
with a freshly generated one, keeping the same constraints and staying inside the
plan's budget.

Gating & guards (this fans out LLM work, so cost is guarded hard):
  * Auth: `Depends(current_user)` — signed-in accounts only.
  * Pro or ONE free plan: a Pro account (server-verified entitlement,
    app/entitlements.py, honoring billing grace) may always plan. A non-Pro account
    gets exactly one free plan (`users.free_plan_used_at`), consumed only when a
    plan SUCCEEDS (same counts-successes-only rule as app/importlimit.py). After
    that a non-Pro caller gets 403 `pro_required` with `reason: "free_plan_used"`
    — 403/pro_required because that is the only response the shipped v1.0 client
    turns into its paywall (see `_free_plan_used_error`).
  * Swaps: a free plan allows FREE_PLAN_SWAP_LIMIT swaps for non-Pro callers (402
    `free_swaps_used`); Pro has a per-day burst cap (BURST_SWAP_PER_DAY, 429).
  * Budget floor/ceiling: rejects a request outside the household's bounds,
    independent of the client, in the user's local units.
  * Rate-limited per account + IP, per-account burst cap, and the 30-day spend cap.

Every successful plan is written to the `budget_plans` ledger (what swap needs) and
its `plan_id` returned; each generated recipe is also written into the shared
recipes cache so a committed meal-plan entry can hydrate its body later. Accepted
recipes are committed into the existing `meal_plan` collection client-side.

Multiplier: with a `store_tier` it is country baseline × tier and `area_type` is
ignored; without one (v1.0) it is country baseline × area type, unchanged.
"""
from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime, timezone
from typing import List, Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from . import budget, burstlimit, config, db, entitlements, llm_cost, ratelimit, spendcap
from .auth.router import current_user
from .auth.service import User
from .models import Appliance, CostEstimate, FoodMood, Recipe
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
    # --- Added after v1.0; a v1.0 client never sends any of these. ---
    # How pricey the user's stores are. When present, multiplier = country baseline
    # × tier and `area_type` is ignored.
    store_tier: Optional[Literal["budget", "standard", "premium"]] = None
    # Equipment the user has — a HARD constraint on every dinner. None = no
    # constraint (v1.0); when present it must have at least one item.
    appliances: Optional[List[Appliance]] = Field(default=None, min_length=1)
    # Soft steer on the kind of dinners (max 3).
    food_moods: Optional[List[FoodMood]] = Field(default=None, max_length=3)


class PlannedRecipe(BaseModel):
    recipe: Recipe
    estimated_cost: CostEstimate  # baseline × multiplier (per-user)
    health_signal: str = ""
    equipment_used: List[Appliance] = Field(default_factory=list)


class BudgetPlanResponse(BaseModel):
    recipes: List[PlannedRecipe]
    currency: str
    budget: float
    min_budget: int
    regional_multiplier: float
    # The ledger id, for the swap endpoint. New field; v1.0 ignores it.
    plan_id: Optional[str] = None
    # True when this plan used the account's free plan (a non-Pro caller).
    is_free: bool = False
    # Swaps the caller has left on this plan: an int for a non-Pro caller on a free
    # plan, None (unlimited, bounded only by the burst cap) for Pro.
    swaps_remaining: Optional[int] = None


class SwapRequest(BaseModel):
    meal_index: int


class SwapResponse(BaseModel):
    plan_id: str
    meal_index: int
    meal: PlannedRecipe
    plan_total: float  # the plan's new adjusted total, in the user's currency
    currency: str
    budget: float
    swaps_used: int
    swaps_remaining: Optional[int] = None  # None for Pro (unlimited)


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #


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


def _resolve_multiplier(req: "BudgetPlanRequest") -> float:
    """The multiplier for a request: with a store tier, country × tier (area type
    ignored); otherwise the v1.0 country × area type."""
    return regional_cost.multiplier_for(req.country, req.area_type, req.store_tier)


NO_EQUIPMENT_LISTED = "no equipment listed"


def _violations(item: "llm.BudgetPlanRecipeLLM", appliances: Optional[List[Appliance]]) -> List[str]:
    """Why this meal breaks the appliance constraint: the appliances it needs that
    the user lacks, or `NO_EQUIPMENT_LISTED` when its `equipment_used` is empty (an
    unverifiable claim counts as a violation). Always empty when the request
    carried no appliances (v1.0): validation is skipped entirely."""
    if not appliances:
        return []
    if not item.equipment_used:
        return [NO_EQUIPMENT_LISTED]
    allowed = set(appliances)
    return sorted({a.value for a in item.equipment_used if a not in allowed})


def _describe_violation(bad: List[str]) -> str:
    return "listed no equipment_used" if bad == [NO_EQUIPMENT_LISTED] else f"needs {', '.join(bad)}"


def _violation_notes(plan: List["llm.BudgetPlanRecipeLLM"], appliances: Optional[List[Appliance]]) -> List[str]:
    notes = []
    for item in plan:
        bad = _violations(item, appliances)
        if bad:
            notes.append(f"{item.recipe.title} ({_describe_violation(bad)})")
    return notes


def _pick_plan(
    first: List["llm.BudgetPlanRecipeLLM"],
    second: List["llm.BudgetPlanRecipeLLM"],
    multiplier: float,
    budget_cap: float,
    appliances: Optional[List[Appliance]] = None,
) -> List["llm.BudgetPlanRecipeLLM"]:
    """Best-effort selection between a plan and its corrective retry.

    Budget comes first: never prefer a plan that exceeds the budget over one that
    doesn't (appliance violations can be repaired afterwards, an overspend can't).
    Among plans within budget, fewer appliance violations wins, then the larger
    total (use as much of the budget as possible). If both exceed, fewer
    violations, then the smaller total. With no appliances (v1.0) violation counts
    are always 0, so this is exactly the original budget-only rule."""
    a, b = _adjusted_total(first, multiplier), _adjusted_total(second, multiplier)
    a_ok, b_ok = a <= budget_cap, b <= budget_cap
    a_bad = len(_violation_notes(first, appliances))
    b_bad = len(_violation_notes(second, appliances))
    if a_ok and b_ok:
        if a_bad != b_bad:
            return first if a_bad < b_bad else second
        return first if a >= b else second
    if a_ok:
        return first
    if b_ok:
        return second
    if a_bad != b_bad:
        return first if a_bad < b_bad else second
    return first if a <= b else second


class ReplacementRejected(Exception):
    """A single-meal replacement still broke a hard rule after its attempts."""


def _replacement_problem(
    item: "llm.BudgetPlanRecipeLLM",
    appliances: Optional[List[Appliance]],
    max_cost: float,
    exclude_titles: List[str],
) -> Optional[str]:
    """Why a candidate replacement is unacceptable (as feedback for a corrective
    attempt), or None if it is fine."""
    bad = _violations(item, appliances)
    if bad:
        have = ", ".join(a.value for a in (appliances or []))
        return f"it {_describe_violation(bad)}; the cook only has: {have}. equipment_used must list at least one."
    if item.baseline_cost.amount > max_cost + 0.01:
        return f"its baseline_cost {item.baseline_cost.amount:.2f} exceeds the maximum {max_cost:.2f}."
    if item.recipe.title.strip().casefold() in {t.strip().casefold() for t in exclude_titles}:
        return "it repeats a dinner already in the plan."
    return None


def _generate_replacement(
    req: "BudgetPlanRequest",
    *,
    max_cost: float,
    exclude_titles: List[str],
    attempts: int,
) -> "llm.BudgetPlanRecipeLLM":
    """Generate ONE replacement dinner honoring the request's household, diet,
    appliances (hard, validated), moods and on-hand items, within `max_cost`
    (baseline space) and outside `exclude_titles`. Tries up to `attempts` times,
    feeding the rejection reason back; raises `ReplacementRejected` if none pass,
    or `llm.LLMError` if the model call itself fails."""
    feedback: Optional[str] = None
    for _ in range(attempts):
        item = llm.generate_single_meal(
            max_cost=max_cost,
            currency=req.currency,
            household_size=req.household_size,
            dietary_preferences=req.dietary_preferences,
            on_hand=req.pantry_items,
            exclude_titles=exclude_titles,
            appliances=[a.value for a in req.appliances] if req.appliances else None,
            food_moods=[m.value for m in req.food_moods] if req.food_moods else None,
            feedback=feedback,
        )
        feedback = _replacement_problem(item, req.appliances, max_cost, exclude_titles)
        if feedback is None:
            return item
    raise ReplacementRejected(feedback)


def _replace_violators(
    req: "BudgetPlanRequest",
    plan: List["llm.BudgetPlanRecipeLLM"],
    baseline_budget: float,
) -> List["llm.BudgetPlanRecipeLLM"]:
    """After the corrective retry, swap out each meal that still needs an appliance
    the user lacks, via the single-meal path (one attempt each, to bound cost).
    A meal that can't be replaced is dropped rather than shipped: a dinner the user
    can't cook is worse than a shorter plan. The per-meal cap is the plan's
    remaining baseline budget plus the cost of the meal being replaced."""
    current: List[Optional["llm.BudgetPlanRecipeLLM"]] = list(plan)
    floor = budget.PER_DINNER_FLOOR * max(req.household_size, 1)
    for i, item in enumerate(plan):
        if not _violations(item, req.appliances):
            continue
        live = [m for m in current if m is not None]
        cap = max(baseline_budget - _baseline_total(live) + item.baseline_cost.amount, floor)
        try:
            current[i] = _generate_replacement(
                req, max_cost=cap, exclude_titles=[m.recipe.title for m in live], attempts=1
            )
        except (llm.LLMError, ReplacementRejected) as exc:
            _log.warning("dropping appliance-violating meal %r: could not replace (%s)", item.recipe.title, exc)
            current[i] = None
    return [m for m in current if m is not None]


def _build_recipe(item: "llm.BudgetPlanRecipeLLM") -> Recipe:
    recipe_id = str(uuid.uuid4())
    return Recipe(
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


def _planned(recipe: Recipe, item: "llm.BudgetPlanRecipeLLM", multiplier: float, currency: str) -> PlannedRecipe:
    estimated = CostEstimate(
        amount=round(item.baseline_cost.amount * multiplier, 2),
        currency=currency,
        basis="llm-v1×regional",
    )
    return PlannedRecipe(
        recipe=recipe,
        estimated_cost=estimated,
        health_signal=item.health_signal,
        equipment_used=item.equipment_used,
    )


def _ledger_meal(recipe: Recipe, item: "llm.BudgetPlanRecipeLLM") -> dict:
    """One meal as stored in `budget_plans.plan_json`: enough for swap to compute
    totals (baseline cost) and exclusions (title) without re-reading recipes."""
    return {
        "recipe_id": recipe.recipe_id,
        "title": recipe.title,
        "baseline_cost": item.baseline_cost.model_dump(mode="json"),
        "health_signal": item.health_signal,
        "equipment_used": [a.value for a in item.equipment_used],
    }


def _free_plan_used_error() -> HTTPException:
    """403 pro_required + reason free_plan_used.

    The v1.0 client (BudgetPlanClient.swift) opens its paywall ONLY for HTTP 403
    with `detail.error_code == "pro_required"`; a 402, or a 403 with any other
    code, falls through to a generic "couldn't build a plan" failure. So the code
    stays "pro_required" and the new distinction rides in `reason` for the v1.1
    client to read."""
    return HTTPException(
        status_code=403,
        detail={
            "error_code": "pro_required",
            "reason": "free_plan_used",
            "message": "You've used your free plan. Plan on a Budget needs Platter Pro.",
        },
    )


# --------------------------------------------------------------------------- #
# Endpoint
# --------------------------------------------------------------------------- #


@router.post("/budget", response_model=BudgetPlanResponse)
def plan_on_a_budget(
    req: BudgetPlanRequest, request: Request, user: User = Depends(current_user)
) -> BudgetPlanResponse:
    # 1. Gate — Pro (server-verified entitlement, app/entitlements.py, not a client
    #    claim) OR the account's one free plan still unused. The free plan is only
    #    CONSUMED after a plan succeeds (step 7), never here.
    is_pro = entitlements.is_pro_user(user.id)
    if not is_pro and db.get_free_plan_used_at(user.id) is not None:
        raise _free_plan_used_error()

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
    multiplier = _resolve_multiplier(req)
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

    appliance_values = [a.value for a in req.appliances] if req.appliances else None
    mood_values = [m.value for m in req.food_moods] if req.food_moods else None

    def _generate(prior_total: Optional[float] = None, violations: Optional[List[str]] = None):
        return llm.generate_budget_plan(
            budget=baseline_budget,
            currency=req.currency,
            household_size=req.household_size,
            dietary_preferences=req.dietary_preferences,
            on_hand=req.pantry_items,
            count=recipe_count,
            prior_total=prior_total,
            rich=steer_rich,
            appliances=appliance_values,
            food_moods=mood_values,
            violations=violations,
        )

    # 5. Generate the week's recipes. If the plan lands under the target band
    #    (< floor) OR has dinners needing appliances the user lacks, run ONE bounded
    #    corrective pass (one retry total, however many things were wrong), then
    #    keep whichever fits best. Any violations left after that are repaired
    #    meal-by-meal via the single-meal path. Ship best-effort either way.
    # Every LLM call here (generation, corrective pass, replacements) is attributed
    # to this account and this plan_id under call_type "budget_plan".
    plan_id = str(uuid.uuid4())
    try:
        with llm_cost.track(user.id, "budget_plan", plan_id):
            generated = _generate()
            violation_notes = _violation_notes(generated, req.appliances)
            undershoot = _adjusted_total(generated, multiplier) < floor_amount
            if undershoot or violation_notes:
                try:
                    retried = _generate(
                        prior_total=round(_baseline_total(generated), 2) if undershoot else None,
                        violations=violation_notes or None,
                    )
                    generated = _pick_plan(generated, retried, multiplier, req.budget, req.appliances)
                except llm.LLMError:
                    # Corrective pass failed — keep the first plan (best-effort).
                    pass
            if req.appliances and _violation_notes(generated, req.appliances):
                generated = _replace_violators(req, generated, baseline_budget)
    except llm.LLMError as exc:
        raise HTTPException(status_code=502, detail={"error_code": exc.code, "message": exc.message})
    if not generated:
        # Every dinner needed equipment the user lacks and none could be replaced.
        raise HTTPException(
            status_code=502,
            detail={
                "error_code": "appliance_constraint_unmet",
                "message": "We couldn't build a plan that fits your appliances. Please try again.",
            },
        )

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

    # 6. Annotate, cache, and apply the multiplier — only for the SELECTED plan, so a
    #    discarded corrective attempt never pollutes the shared cache.
    planned: List[PlannedRecipe] = []
    ledger_meals: List[dict] = []
    for item in generated:
        recipe = _build_recipe(item)
        db.save_recipe(recipe)  # organically grows the annotated shared cache
        planned.append(_planned(recipe, item, multiplier, req.currency))
        ledger_meals.append(_ledger_meal(recipe, item))

    # 7. Ledger + free plan. The plan is written first; the free plan is consumed
    #    only now that a plan has succeeded (a failed generation costs the user
    #    nothing). A Pro account's plan never burns the free plan. If two requests
    #    race, the compare-and-set lets one claim it; the loser still gets the plan
    #    it already paid the LLM for.
    now_iso = datetime.now(timezone.utc).isoformat()
    request_state = req.model_dump(mode="json")
    request_state["resolved_multiplier"] = multiplier  # swap must reuse THIS one
    db.save_budget_plan(
        plan_id=plan_id,
        user_id=user.id,
        created_at=now_iso,
        is_free=not is_pro,
        request_json=json.dumps(request_state),
        plan_json=json.dumps(ledger_meals),
        budget_baseline=baseline_budget,
    )
    if not is_pro:
        db.claim_free_plan(user.id, now_iso)

    return BudgetPlanResponse(
        recipes=planned,
        currency=req.currency,
        budget=req.budget,
        min_budget=min_local,
        regional_multiplier=multiplier,
        plan_id=plan_id,
        is_free=not is_pro,
        swaps_remaining=None if is_pro else config.FREE_PLAN_SWAP_LIMIT,
    )


# --------------------------------------------------------------------------- #
# Swap
# --------------------------------------------------------------------------- #


@router.post("/budget/{plan_id}/swap", response_model=SwapResponse)
def swap_meal(
    plan_id: str, body: SwapRequest, request: Request, user: User = Depends(current_user)
) -> SwapResponse:
    # 1. The plan must exist AND belong to the caller. Same 404 for both, so plan
    #    ids can't be probed across accounts.
    row = db.get_budget_plan(plan_id)
    if row is None or row["user_id"] != user.id:
        raise HTTPException(
            status_code=404, detail={"error_code": "plan_not_found", "message": "Plan not found."}
        )

    # 2. Swap entitlement. Pro: always (bounded by the burst cap below). Non-Pro:
    #    only on their free plan, and at most FREE_PLAN_SWAP_LIMIT times. Checked
    #    BEFORE the burst counter so a paywalled request doesn't burn allowance.
    is_pro = entitlements.is_pro_user(user.id)
    if not is_pro:
        if not row["is_free"]:
            raise HTTPException(
                status_code=403,
                detail={"error_code": "pro_required", "message": "Swapping meals needs Platter Pro."},
            )
        if row["swaps_used"] >= config.FREE_PLAN_SWAP_LIMIT:
            raise HTTPException(
                status_code=402,
                detail={
                    "error_code": "free_swaps_used",
                    "message": "You've used your free swaps for this plan.",
                    "limit": config.FREE_PLAN_SWAP_LIMIT,
                },
            )

    # 3. Rate limits, same layering as plan generation.
    try:
        ratelimit.check(user.id, _client_ip(request))
    except ratelimit.RateLimitExceeded as exc:
        raise HTTPException(status_code=429, detail=str(exc))
    try:
        burstlimit.check_swap(user.id)
    except burstlimit.BurstLimitExceeded as exc:
        raise HTTPException(
            status_code=429,
            detail={
                "error_code": exc.code,
                "message": "You've reached today's swap limit. Please try again tomorrow.",
                "limit": exc.limit,
                "window": exc.window_label,
            },
        )
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

    # 4. Reload the stored plan and request; reuse the multiplier the plan was
    #    priced with (not a fresh lookup), so totals stay consistent.
    meals: List[dict] = json.loads(row["plan_json"])
    if not 0 <= body.meal_index < len(meals):
        raise HTTPException(
            status_code=400,
            detail={"error_code": "invalid_meal_index", "message": "No such meal in this plan."},
        )
    request_state = json.loads(row["request_json"])
    multiplier = float(request_state.get("resolved_multiplier") or 1.0)
    req = BudgetPlanRequest.model_validate(request_state)

    # 5. Per-meal budget (baseline space) = what's left in the plan's budget plus
    #    the cost of the meal being replaced. Floored so an over-budget plan can't
    #    produce a zero/negative cap.
    old_cost = float(meals[body.meal_index]["baseline_cost"]["amount"])
    total = sum(float(m["baseline_cost"]["amount"]) for m in meals)
    cap = max(
        row["budget_baseline"] - total + old_cost,
        budget.PER_DINNER_FLOOR * max(req.household_size, 1),
    )
    exclude = [m["title"] for m in meals]

    # 6. Generate exactly one replacement (one corrective attempt allowed), tracked
    #    against this plan. Rejections and failures don't consume a swap.
    try:
        with llm_cost.track(user.id, "budget_swap", plan_id):
            item = _generate_replacement(req, max_cost=cap, exclude_titles=exclude, attempts=2)
    except llm.LLMError as exc:
        raise HTTPException(status_code=502, detail={"error_code": exc.code, "message": exc.message})
    except ReplacementRejected as exc:
        raise HTTPException(
            status_code=502,
            detail={
                "error_code": "swap_constraint_unmet",
                "message": "We couldn't find a replacement that fits. Please try again.",
                "reason": str(exc),
            },
        )

    # 7. Commit: optimistic write so two concurrent swaps can't both apply against
    #    the same stored plan; only then cache the recipe body.
    recipe = _build_recipe(item)
    meals[body.meal_index] = _ledger_meal(recipe, item)
    if not db.update_budget_plan_after_swap(plan_id, json.dumps(meals), row["swaps_used"]):
        raise HTTPException(
            status_code=409,
            detail={"error_code": "plan_changed", "message": "This plan just changed. Please try again."},
        )
    db.save_recipe(recipe)

    new_total = round(sum(float(m["baseline_cost"]["amount"]) for m in meals) * multiplier, 2)
    return SwapResponse(
        plan_id=plan_id,
        meal_index=body.meal_index,
        meal=_planned(recipe, item, multiplier, req.currency),
        plan_total=new_total,
        currency=req.currency,
        budget=req.budget,
        swaps_used=row["swaps_used"] + 1,
        swaps_remaining=(
            None if is_pro else max(config.FREE_PLAN_SWAP_LIMIT - (row["swaps_used"] + 1), 0)
        ),
    )
