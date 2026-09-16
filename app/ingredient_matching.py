"""Shared ingredient-name normalization + pantry matching.

This is the foundation the (future) pantry-suggestion feature will sit on: it
answers "does the user's pantry item X appear in this recipe?" reliably, without
the two false results the cache-viability probe turned up.

Two problems it fixes:

  1. Ingredient names arrive in wildly different shapes depending on source.
     Caption/article extraction splits quantity/unit/notes into their own fields,
     so `name` is already a bare ingredient ("cooked chickpeas"). But JSON-LD
     ("structured") recipes keep the WHOLE line in `name`
     ("1½ cups cooked chickpeas (drained and rinsed)") — deliberately, to avoid
     inventing a split. `normalize_ingredient_name` collapses both shapes to the
     same canonical token so matching compares like with like.
  2. Naïve substring matching produced false positives — the probe found "egg"
     matching inside "veggies". `ingredients_match` uses word-boundary matching
     so a pantry item only matches whole words.

`name` is never mutated for display; normalization output lands in the separate
`Ingredient.normalized_name` field (populated at write time in db.save_recipe),
and matching reads that field.

Known, accepted limitation: a bare pantry item like "pepper" matches BOTH
"black pepper" and "bell pepper" (both contain the whole word "pepper"). That is
expected — disambiguating those needs real word-sense logic and is out of scope
for this foundation.
"""
from __future__ import annotations

import re
import unicodedata
from typing import List

from .models import Ingredient

# --------------------------------------------------------------------------- #
# Normalization
# --------------------------------------------------------------------------- #

# Unicode vulgar-fraction characters (½ ⅓ ¼ …). We don't need their values here,
# only to recognize and strip them as part of a leading quantity.
_FRACTION_CHARS = "¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞↉"

# A leading quantity token: digits and/or unicode fractions, optionally joined by
# spaces, slashes (1/2), dots (1.5), or range separators (1-2, 1–2). Anchored to
# the start so it only strips a leading measurement, never digits inside a name.
_LEADING_QTY_RE = re.compile(
    r"^\s*[\d" + _FRACTION_CHARS + r"]"
    r"[\d" + _FRACTION_CHARS + r"\s/.\-–—]*"
)

# Common units to strip when they lead the remaining text (after any quantity).
# Kept deliberately small (CLAUDE.md §5's canonical set + obvious singular/plural
# and spelled-out variants); this is a matching aid, not a full unit ontology.
_UNITS = [
    "cups", "cup",
    "tablespoons", "tablespoon", "tbsps", "tbsp",
    "teaspoons", "teaspoon", "tsps", "tsp",
    "ounces", "ounce", "oz",
    "pounds", "pound", "lbs", "lb",
    "grams", "gram", "kg", "kgs", "g",
    "milliliters", "milliliter", "ml",
    "liters", "liter", "litres", "litre", "l",
    "cloves", "clove",
    "pinches", "pinch",
    "dashes", "dash",
    "cans", "can",
    "packages", "package", "pkgs", "pkg",
]
# Longest-first alternation so "cups" wins over "cup", "tbsp" over nothing, etc.
_LEADING_UNIT_RE = re.compile(
    r"^(?:" + "|".join(sorted(_UNITS, key=len, reverse=True)) + r")\b\.?\s*"
)

# A parenthetical aside anywhere in the line, e.g. "(drained and rinsed)".
_PARENS_RE = re.compile(r"\([^)]*\)")

# A trailing comma-introduced clause, e.g. "chickpeas, drained and rinsed".
_TRAILING_CLAUSE_RE = re.compile(r",.*$")

# Punctuation/whitespace to shave off the ends after everything else (e.g. the
# stray "*" footnote marker in "tahini*").
_EDGE_CHARS = " \t\r\n*.,;:!-–—\"'`()[]"


def normalize_ingredient_name(raw: str) -> str:
    """Reduce a raw ingredient line to a canonical, matchable name.

    Steps, in order: lowercase → drop parentheticals → drop a trailing
    comma-clause → strip a leading quantity → strip a leading unit → trim edge
    punctuation/whitespace and collapse internal runs of spaces.

    Examples:
        "1½ cups cooked chickpeas (drained and rinsed)" -> "cooked chickpeas"
        "⅓ cup smooth tahini*"                          -> "smooth tahini"
        "chickpeas"                                     -> "chickpeas"
    """
    if not raw:
        return ""

    # Normalize compatibility forms so e.g. a precomposed "1½" and its decomposed
    # equivalent behave identically; keep the vulgar-fraction glyphs intact.
    text = unicodedata.normalize("NFC", raw).lower()

    text = _PARENS_RE.sub(" ", text)
    text = _TRAILING_CLAUSE_RE.sub("", text)
    text = _LEADING_QTY_RE.sub("", text)
    text = _LEADING_UNIT_RE.sub("", text)

    text = text.strip(_EDGE_CHARS)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def normalize_ingredients(ingredients: List[Ingredient]) -> List[Ingredient]:
    """Return copies of `ingredients` with `normalized_name` (re)computed from
    `name`. Pure/idempotent: safe to run on already-normalized recipes (a
    cache-hit re-save, the backfill, etc.). Used by db.save_recipe so every
    stored recipe carries normalized names regardless of source path."""
    return [
        ing.model_copy(update={"normalized_name": normalize_ingredient_name(ing.name)})
        for ing in ingredients
    ]


# --------------------------------------------------------------------------- #
# Matching
# --------------------------------------------------------------------------- #


def ingredients_match(pantry_item: str, recipe_ingredient: str) -> bool:
    """True if a pantry item appears as a whole word (or phrase) in a recipe
    ingredient.

    `pantry_item` is raw user text and is normalized here; `recipe_ingredient` is
    assumed already normalized/stored (i.e. an `Ingredient.normalized_name`). The
    match is word-boundary anchored, so "egg" does NOT match inside "veggies",
    and case-insensitive as a cheap safety net.
    """
    needle = normalize_ingredient_name(pantry_item)
    if not needle:
        return False
    pattern = r"\b" + re.escape(needle) + r"\b"
    return re.search(pattern, recipe_ingredient, flags=re.IGNORECASE) is not None
