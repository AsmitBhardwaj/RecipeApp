"""Signal-check heuristic (CLAUDE.md §5).

Proceed to full LLM extraction when the caption contains >=2 of:
  * measurement units (cup, tbsp, oz, g, ...)
  * a numbered-list pattern
  * ingredient-list keywords
Otherwise go straight to the dish-ID + generic-recipe fallback.
"""
from __future__ import annotations

import re

_UNIT_RE = re.compile(
    r"\b("
    r"cups?|tbsp|tablespoons?|tsp|teaspoons?|"
    r"oz|ounces?|lbs?|pounds?|"
    r"g|grams?|kg|kilograms?|"
    r"ml|milliliters?|l|liters?|litres?|"
    r"cloves?|pinch|dash"
    r")\b",
    re.IGNORECASE,
)

# A line that starts with "1." / "2)" / "-" / "•" / "step 1", etc.
_NUMBERED_RE = re.compile(
    r"(?m)^\s*(?:\d+[\.\):]|[-*•▢]|step\s*\d+)", re.IGNORECASE
)

_KEYWORD_RE = re.compile(
    r"(ingredients?|you(?:'ll| will)? need|what you need|recipe|instructions?|directions?|method)",
    re.IGNORECASE,
)


def has_recipe_signal(caption: str) -> bool:
    if not caption:
        return False
    score = 0
    if _UNIT_RE.search(caption):
        score += 1
    if _NUMBERED_RE.search(caption):
        score += 1
    if _KEYWORD_RE.search(caption):
        score += 1
    return score >= 2
