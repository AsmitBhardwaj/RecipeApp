"""schema.org Recipe JSON-LD parser + normalizer (CLAUDE.md §5, web tier).

Most recipe blogs embed a machine-readable recipe as JSON-LD for SEO:

    <script type="application/ld+json"> { "@type": "Recipe", ... } </script>

This is ground-truth structured data straight from the page — no LLM guessing —
so when it's present AND complete we use it directly and mark the recipe
`source_type: "structured"` with confidence 1.0.

"Complete" is a hard contract: a recipe counts as structured ONLY if it has
both ingredients and instructions. Anything partial returns None, and the
orchestrator falls through to the article-text + LLM path instead of shipping a
half recipe at full confidence.

JSON-LD in the wild is messy — `@type` may be a string or a list, the recipe may
be nested under `@graph`, instructions come as a plain string / list of strings
/ HowToStep objects / HowToSection groupings, and image/yield/time fields vary
in shape. `_normalize` absorbs all of that. Ingredient lines are kept whole in
`name` (not split into quantity/unit) — that's the deliberate v1 choice: exact
site text, zero invention.
"""
from __future__ import annotations

import html as _html
import json
import re
from dataclasses import dataclass
from typing import List, Optional

from bs4 import BeautifulSoup

from ..models import Confidence, Ingredient, Instruction, LLMRecipe, Servings


@dataclass
class ParsedRecipe:
    recipe: LLMRecipe
    image_url: Optional[str]


_ISO_DURATION_RE = re.compile(
    r"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"
)


def parse_recipe_jsonld(html: str) -> Optional[ParsedRecipe]:
    """Return a complete structured recipe from the page's JSON-LD, or None."""
    if not html:
        return None
    soup = BeautifulSoup(html, "lxml")
    for tag in soup.find_all("script", type="application/ld+json"):
        raw = tag.string or tag.get_text() or ""
        if not raw.strip():
            continue
        try:
            data = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            continue
        obj = _find_recipe(data)
        if obj is not None:
            parsed = _normalize(obj)
            if parsed is not None:
                return parsed
    return None


# --------------------------------------------------------------------------- #
# Locating the Recipe object
# --------------------------------------------------------------------------- #


def _is_recipe(obj: dict) -> bool:
    t = obj.get("@type")
    if isinstance(t, list):
        return any(isinstance(x, str) and x.lower() == "recipe" for x in t)
    return isinstance(t, str) and t.lower() == "recipe"


def _find_recipe(node) -> Optional[dict]:
    if isinstance(node, dict):
        if _is_recipe(node):
            return node
        if "@graph" in node:
            found = _find_recipe(node["@graph"])
            if found is not None:
                return found
        return None
    if isinstance(node, list):
        for item in node:
            found = _find_recipe(item)
            if found is not None:
                return found
    return None


# --------------------------------------------------------------------------- #
# Normalization
# --------------------------------------------------------------------------- #


def _clean(text: str) -> str:
    return _html.unescape(text).strip()


def _as_list(value) -> list:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def _normalize(obj: dict) -> Optional[ParsedRecipe]:
    title = obj.get("name")
    if not isinstance(title, str) or not title.strip():
        return None

    ingredients = [
        Ingredient(name=_clean(line))
        for line in _as_list(obj.get("recipeIngredient"))
        if isinstance(line, str) and line.strip()
    ]
    instructions = _normalize_instructions(obj.get("recipeInstructions"))

    # Completeness contract: both required, or this isn't a "structured" recipe.
    if not ingredients or not instructions:
        return None

    recipe = LLMRecipe(
        title=_clean(title),
        servings=_parse_yield(obj.get("recipeYield")),
        prep_time_minutes=_iso_minutes(obj.get("prepTime")),
        cook_time_minutes=_iso_minutes(obj.get("cookTime")),
        total_time_minutes=_iso_minutes(obj.get("totalTime")),
        ingredients=ingredients,
        instructions=instructions,
        confidence=Confidence(
            overall=1.0,
            ingredients_complete=True,
            instructions_complete=True,
            missing_fields=[],
        ),
    )
    return ParsedRecipe(recipe=recipe, image_url=_first_image(obj.get("image")))


def _normalize_instructions(raw) -> List[Instruction]:
    steps: List[str] = []

    def add(text) -> None:
        if isinstance(text, str):
            cleaned = _clean(text)
            if cleaned:
                steps.append(cleaned)

    if isinstance(raw, str):
        for line in raw.split("\n"):
            add(line)
    elif isinstance(raw, dict):
        return _normalize_instructions([raw])
    elif isinstance(raw, list):
        for item in raw:
            if isinstance(item, str):
                add(item)
            elif isinstance(item, dict):
                # HowToSection groups steps under itemListElement.
                if item.get("@type") == "HowToSection" or "itemListElement" in item:
                    for sub in _as_list(item.get("itemListElement")):
                        if isinstance(sub, str):
                            add(sub)
                        elif isinstance(sub, dict):
                            add(sub.get("text") or sub.get("name"))
                else:  # HowToStep or a bare {text: ...}
                    add(item.get("text") or item.get("name"))

    return [Instruction(step_number=i + 1, text=s) for i, s in enumerate(steps)]


def _parse_yield(value) -> Servings:
    if isinstance(value, list):
        value = value[0] if value else None
    if value is None:
        return Servings()
    if isinstance(value, (int, float)):
        return Servings(amount=float(value))
    if isinstance(value, str):
        m = re.search(r"\d+(?:\.\d+)?", value)
        if m:
            return Servings(amount=float(m.group()))
        cleaned = _clean(value)
        return Servings(unit=cleaned or None)
    return Servings()


def _iso_minutes(value) -> Optional[float]:
    """Parse an ISO-8601 duration (e.g. 'PT1H30M') to minutes."""
    if not isinstance(value, str):
        return None
    m = _ISO_DURATION_RE.match(value.strip())
    if not m:
        return None
    days, hours, minutes, seconds = (int(g) if g else 0 for g in m.groups())
    total = days * 1440 + hours * 60 + minutes + round(seconds / 60)
    return float(total) if total > 0 else None


def _first_image(value) -> Optional[str]:
    """Pull the first usable URL from image (string | list | ImageObject)."""
    if value is None:
        return None
    if isinstance(value, str):
        return value.strip() or None
    if isinstance(value, dict):
        url = value.get("url")
        return url.strip() if isinstance(url, str) and url.strip() else None
    if isinstance(value, list):
        for item in value:
            found = _first_image(item)
            if found:
                return found
    return None
