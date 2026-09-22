"""Regional cost multiplier for Plan on a Budget (docs/budget-meal-planning.md §3.4).

Settled per the task spec: a small STATIC lookup (not an LLM call), applied over
an LLM-estimated, location-independent per-recipe basket cost:

    estimated_cost = baseline_basket_cost × multiplier_for(region)

Cost is always presented to the user as a labeled ESTIMATE, never store-accurate,
so a coarse multiplier is sufficient. When the region is unknown/unmapped we fall
back to the national-average `DEFAULT_MULTIPLIER` (1.0).

Ordering sanity (the doc's pre-ship gut-check): high-cost metros (SF, NYC, Boston)
must rank above the national average, which must rank above low-cost rural areas.
Keys are matched case-insensitively on a normalized region string sent by the
client. Values are round numbers on purpose — this is a calibrated estimate, not
a dataset.
"""
from __future__ import annotations

from typing import Optional

DEFAULT_MULTIPLIER: float = 1.0

# Region key (lowercased) → multiplier vs. the US national average (1.0).
# Seeded with well-known US metros/regions plus a few countries. Extend freely;
# unknown regions get DEFAULT_MULTIPLIER.
REGIONAL_MULTIPLIERS: dict[str, float] = {
    # High-cost US metros
    "san francisco": 1.35,
    "san francisco bay area": 1.35,
    "new york": 1.30,
    "new york city": 1.30,
    "manhattan": 1.35,
    "honolulu": 1.35,
    "boston": 1.25,
    "seattle": 1.20,
    "los angeles": 1.20,
    "washington dc": 1.20,
    "san diego": 1.18,
    # Mid / slightly-above-average
    "chicago": 1.10,
    "denver": 1.08,
    "miami": 1.10,
    "portland": 1.10,
    "austin": 1.05,
    "atlanta": 1.02,
    # National baseline
    "national": 1.00,
    "united states": 1.00,
    "usa": 1.00,
    # Lower-cost US regions
    "dallas": 0.98,
    "houston": 0.96,
    "phoenix": 0.97,
    "midwest": 0.90,
    "rural midwest": 0.85,
    "south": 0.90,
    "rural": 0.85,
    # A few countries (coarse, vs. US baseline)
    "canada": 1.05,
    "united kingdom": 1.10,
    "australia": 1.15,
    "india": 0.55,
    "mexico": 0.70,
}


def multiplier_for(region: Optional[str]) -> float:
    """The cost multiplier for `region`, or `DEFAULT_MULTIPLIER` when the region is
    missing or unmapped."""
    if not region:
        return DEFAULT_MULTIPLIER
    return REGIONAL_MULTIPLIERS.get(region.strip().lower(), DEFAULT_MULTIPLIER)


# The regions we actually offer as pickable buckets in the client's onboarding
# "grocery costs" step and Account settings. This is a curated SELECTION of the
# keys above (aliases like "usa"/"united states"/"manhattan" are collapsed into a
# single representative) — it invents no new categories and no new multipliers.
#
# It is the source of truth the iOS picker mirrors: every `key` here MUST exist
# verbatim in REGIONAL_MULTIPLIERS, so a stored selection always resolves to a
# real bucket and never hits the DEFAULT_MULTIPLIER fallback. The iOS enum
# `RecipeKit.GroceryRegion` must keep its raw values in sync with these keys.
#
# Each entry is (stored_key, human_label). Ordered high-cost → low-cost, US
# metros first, then the national baseline, then a few countries.
SELECTABLE_REGIONS: list[tuple[str, str]] = [
    ("san francisco", "San Francisco Bay Area"),
    ("honolulu", "Honolulu"),
    ("new york city", "New York City"),
    ("boston", "Boston"),
    ("seattle", "Seattle"),
    ("los angeles", "Los Angeles"),
    ("washington dc", "Washington, D.C."),
    ("san diego", "San Diego"),
    ("miami", "Miami"),
    ("portland", "Portland"),
    ("chicago", "Chicago"),
    ("denver", "Denver"),
    ("austin", "Austin"),
    ("atlanta", "Atlanta"),
    ("national", "United States (national average)"),
    ("dallas", "Dallas"),
    ("phoenix", "Phoenix"),
    ("houston", "Houston"),
    ("south", "U.S. South"),
    ("midwest", "U.S. Midwest"),
    ("rural", "Rural / small town"),
    ("rural midwest", "Rural Midwest"),
    ("australia", "Australia"),
    ("united kingdom", "United Kingdom"),
    ("canada", "Canada"),
    ("mexico", "Mexico"),
    ("india", "India"),
]


def selectable_region_keys() -> list[str]:
    """The stored keys for the pickable regions, in display order."""
    return [key for key, _label in SELECTABLE_REGIONS]
