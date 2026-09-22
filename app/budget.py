"""Budget math for Plan on a Budget (docs/budget-meal-planning.md).

The minimum weekly budget is per-person, not flat: `household_size ×
MIN_BUDGET_PER_PERSON`, rounded to the nearest $5. This is the single source of
truth on the server; the iOS client mirrors it in RecipeKit's `BudgetMath` so the
stepper caption and floor match exactly.
"""
from __future__ import annotations

from . import config

_INCREMENT = 5


def _round_to_increment(value: float, increment: int = _INCREMENT) -> int:
    """Round to the nearest `increment` (default $5)."""
    return int(round(value / increment) * increment)


def min_budget(household_size: int) -> int:
    """The minimum allowed weekly budget for a household of `household_size`,
    scaled per person and rounded to the nearest $5. Household size is clamped to
    at least 1 so a bogus 0/negative can't drive the floor to $0."""
    hs = max(1, int(household_size))
    return _round_to_increment(hs * config.MIN_BUDGET_PER_PERSON)
