"""Regional cost multiplier for Plan on a Budget (docs/budget-meal-planning.md §3.4).

Settled per the task spec: a small STATIC lookup (not an LLM call), applied over
an LLM-estimated, location-independent per-recipe basket cost:

    estimated_cost = baseline_basket_cost × multiplier_for(country, area_type)

The multiplier is a flat, two-part table (v1):

    multiplier = country_baseline(country) × area_modifier(area_type)

- `country_baseline` is a coarse cost-of-living factor vs. the US national
  average (1.0). Unlisted/unknown countries fall back to `DEFAULT_BASELINE`.
- `area_modifier` nudges that up for a city, down for a rural area, with a
  suburb as the 1.0 anchor. A missing area type falls back to
  `DEFAULT_AREA_MODIFIER`.

Cost is always presented to the user as a labeled ESTIMATE, never store-accurate,
so a coarse multiplier is sufficient. The final multiplier is rounded to two
decimals so the annotated per-recipe cost stays tidy.

Ordering sanity (the doc's pre-ship gut-check): a high-cost country/city (e.g.
Switzerland/city) must rank above the US suburb baseline, which must rank above a
low-cost country/rural area (e.g. India/rural). Values are round numbers on
purpose — this is a calibrated estimate, not a dataset.

Country is keyed on the ISO 3166-1 alpha-2 code (uppercased); area type on one of
the fixed keys below. The iOS side (`RecipeKit.AreaType` + the country picker's
stored ISO codes) must keep its values in sync with these keys.
"""
from __future__ import annotations

from typing import Optional

DEFAULT_BASELINE: float = 1.0
DEFAULT_AREA_MODIFIER: float = 1.0

# Area-type modifier, applied on top of the country baseline. Suburb is the 1.0
# anchor; city is pricier, rural cheaper.
AREA_MODIFIERS: dict[str, float] = {
    "city": 1.15,
    "suburb": 1.00,
    "rural": 0.85,
}

# Country baseline vs. the US national average (1.0), keyed on ISO 3166-1 alpha-2.
# Curated, coarse, and round; every other country falls back to DEFAULT_BASELINE.
COUNTRY_BASELINES: dict[str, float] = {
    "US": 1.00,
    "CA": 1.05,
    "GB": 1.10,
    "IE": 1.10,
    "AU": 1.15,
    "NZ": 1.10,
    "CH": 1.45,
    "NO": 1.35,
    "SE": 1.10,
    "DE": 1.00,
    "FR": 1.05,
    "NL": 1.05,
    "ES": 0.90,
    "IT": 0.95,
    "MX": 0.70,
    "IN": 0.55,
}


def country_baseline(country: Optional[str]) -> float:
    """The cost baseline for an ISO alpha-2 country code, or `DEFAULT_BASELINE`
    when the code is missing or unmapped."""
    if not country:
        return DEFAULT_BASELINE
    return COUNTRY_BASELINES.get(country.strip().upper(), DEFAULT_BASELINE)


def area_modifier(area_type: Optional[str]) -> float:
    """The modifier for an area type (`city`/`suburb`/`rural`), or
    `DEFAULT_AREA_MODIFIER` when it is missing or unrecognized."""
    if not area_type:
        return DEFAULT_AREA_MODIFIER
    return AREA_MODIFIERS.get(area_type.strip().lower(), DEFAULT_AREA_MODIFIER)


def multiplier_for(country: Optional[str], area_type: Optional[str]) -> float:
    """The cost multiplier for a (country, area_type) pair: the country baseline
    times the area-type modifier, rounded to two decimals. Missing/unknown parts
    fall back to their respective defaults (both 1.0), so an entirely unset
    location resolves to the 1.0 national average."""
    return round(country_baseline(country) * area_modifier(area_type), 2)
