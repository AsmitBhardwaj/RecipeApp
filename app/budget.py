"""Budget math for Plan on a Budget (docs/budget-meal-planning.md).

One consistent cost model, all derived from a small set of per-person baseline
(US national-average, ingredients-only) per-dinner anchors — NOT independently
guessed numbers:

    per_dinner_floor        $3   below this a dinner isn't a real meal
    per_dinner_comfortable  $8   above this, steer toward richer recipes
    per_dinner_ceiling      $12  above this, more money ≠ a better normal dinner
    min_recipe_count        4
    max_recipe_count        7    (days in a week; = config.BUDGET_PLAN_RECIPE_COUNT)

Everything else is derived from those:

    min_budget(P) = per_dinner_floor    × min_recipe_count × P   (weekly floor)
    max_budget(P) = per_dinner_ceiling  × max_recipe_count × P   (weekly cap)

All amounts here are in BASELINE (location-independent) space, the same space the
LLM reasons in and that `mealplan.py` converts the user's budget into
(budget ÷ regional multiplier). The client mirrors `min_budget` in RecipeKit's
`BudgetMath` as an approximate, region-agnostic stepper hint; the server is
authoritative and enforces both bounds after the regional conversion.
"""
from __future__ import annotations

import os

from . import config

_INCREMENT = 5

# Per-person, per-dinner baseline cost anchors (USD). Env-overridable like the
# rest of config; the iOS BudgetMath mirror tracks the floor/ceiling nominally.
PER_DINNER_FLOOR: float = float(os.getenv("BUDGET_PER_DINNER_FLOOR", "3"))
PER_DINNER_COMFORTABLE: float = float(os.getenv("BUDGET_PER_DINNER_COMFORTABLE", "8"))
PER_DINNER_RICHNESS_CEILING: float = float(os.getenv("BUDGET_PER_DINNER_CEILING", "12"))
MIN_RECIPE_COUNT: int = int(os.getenv("BUDGET_MIN_RECIPE_COUNT", "4"))


def _max_recipe_count() -> int:
    """Days-in-a-week ceiling on dinners — the existing knob."""
    return config.BUDGET_PLAN_RECIPE_COUNT


def _round_to_increment(value: float, increment: int = _INCREMENT) -> int:
    """Round to the nearest `increment` (default $5)."""
    return int(round(value / increment) * increment)


def min_budget(household_size: int) -> int:
    """Minimum allowed weekly budget (baseline space): the cheapest realistic plan
    is `min_recipe_count` dinners at the per-dinner floor, per person. Rounded to
    the nearest $5. Household size clamped to ≥ 1."""
    hs = max(1, int(household_size))
    return _round_to_increment(PER_DINNER_FLOOR * MIN_RECIPE_COUNT * hs)


def max_budget(household_size: int) -> int:
    """Maximum allowed weekly budget (baseline space): `max_recipe_count` dinners
    at the per-dinner richness ceiling, per person. Above this, extra money stops
    buying a better normal week. Rounded to the nearest $5."""
    hs = max(1, int(household_size))
    return _round_to_increment(PER_DINNER_RICHNESS_CEILING * _max_recipe_count() * hs)


def target_recipe_count(baseline_budget: float, household_size: int) -> int:
    """How many dinners to ask for. Normally `max_recipe_count` (7), but when the
    budget is so low that 7 dinners would each fall below the per-person floor, cut
    the count down (toward `min_recipe_count`) so each dinner clears the floor
    rather than letting the LLM undershoot chasing 7."""
    hs = max(1, int(household_size))
    max_count = _max_recipe_count()
    per_dinner = baseline_budget / (max_count * hs) if max_count and hs else 0.0
    if per_dinner >= PER_DINNER_FLOOR:
        return max_count
    affordable = int(baseline_budget // (hs * PER_DINNER_FLOOR)) if PER_DINNER_FLOOR else max_count
    return max(MIN_RECIPE_COUNT, min(max_count, affordable))


def wants_rich(baseline_budget: float, household_size: int) -> bool:
    """Whether the budget is generous enough (per person, per dinner at the full
    `max_recipe_count`) to steer the LLM toward richer recipes instead of more
    dinners. True above the comfortable threshold; a request over the cap is
    rejected before we get here, so this never exceeds the richness ceiling."""
    hs = max(1, int(household_size))
    max_count = _max_recipe_count()
    per_dinner = baseline_budget / (max_count * hs) if max_count and hs else 0.0
    return per_dinner > PER_DINNER_COMFORTABLE
