"""LLM extraction + dish-ID fallback (CLAUDE.md §5).

The three system prompts are used *verbatim* from the spec. All model output is
parsed as JSON and validated against a Pydantic model; malformed output gets
exactly one corrective retry, then fails cleanly (CLAUDE.md §5 "Validation").

Thinking is disabled: this is a reformat-caption-into-JSON task, so spending
thinking tokens would only add cost/latency (CLAUDE.md §7).
"""
from __future__ import annotations

import json
from typing import List, Optional, Type, TypeVar

from openai import OpenAI, OpenAIError
from pydantic import BaseModel, ValidationError

from .. import config
from ..models import DishIdentification, Ingredient, LLMRecipe

T = TypeVar("T", bound=BaseModel)


class LLMError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


# --------------------------------------------------------------------------- #
# Prompts — used verbatim from CLAUDE.md §5
# --------------------------------------------------------------------------- #

EXTRACTION_SYSTEM_PROMPT = """\
You are a recipe extraction engine. You will be given raw text scraped from a
social media video caption. Your job is to extract a structured recipe from
this text — nothing else.

RULES:
1. Output ONLY valid JSON matching the schema provided. No prose, no markdown
   fences, no explanation.
2. Never invent ingredients, quantities, or steps that are not stated or
   strongly implied by the source text. If a quantity is not given, set
   "quantity": null and "unit": null but still include the ingredient by name.
3. Split every ingredient line into quantity, unit, and name separately.
   Normalize units to standard abbreviations (tbsp, tsp, cup, oz, g, ml, lb).
   If a unit is ambiguous or colloquial (e.g. "a splash", "a good glug"), keep
   it as given in the "notes" field and leave "unit" null.
4. Reconstruct instructions as a clean, numbered sequence even if the source
   rambles or is out of order — infer logical cooking order from context. For
   each step, if the text states or clearly implies a single cooking duration
   (e.g. "bake for 20 minutes", "simmer 1 hour"), set that step's
   "duration_seconds" to that time in total seconds; otherwise set it null.
   Never guess a duration that isn't stated.
5. If title is not explicitly stated, generate a concise, descriptive title
   from the dish being made — never a generic phrase like "Recipe video."
6. Populate the "confidence" object honestly:
   - "ingredients_complete": false if items seem missing (e.g. instructions
     reference an ingredient never listed)
   - "instructions_complete": false if steps seem to skip logical stages
   - List any fields you could not determine in "missing_fields"
   - Lower "overall" confidence when the caption is sparse or ambiguous
7. If the source text contains no discernible recipe at all, return the JSON
   with empty ingredients/instructions arrays and "overall": 0.

Input will be provided as:
CAPTION: <text>"""

DISH_ID_SYSTEM_PROMPT = """\
You are given a possibly fragmentary caption from a cooking video. Identify
the specific dish being made. Respond with JSON only:

{
  "dish_name": "string, or null if not determinable",
  "cuisine": "string | null",
  "confidence": "number 0-1",
  "distinguishing_details": ["any specifics mentioned, e.g. 'spicy',
                              'baked not fried', 'vegan'"]
}

Base this ONLY on what's stated or clearly implied. If too sparse to identify
even a general dish, set dish_name to null."""

ARTICLE_EXTRACTION_SYSTEM_PROMPT = """\
You are a recipe extraction engine. You will be given the main article text
scraped from a recipe web page (navigation, ads, and comments already removed).
Your job is to extract a structured recipe from this text — nothing else.

RULES:
1. Output ONLY valid JSON matching the schema provided. No prose, no markdown
   fences, no explanation.
2. Never invent ingredients, quantities, or steps that are not stated or
   strongly implied by the source text. If a quantity is not given, set
   "quantity": null and "unit": null but still include the ingredient by name.
3. Split every ingredient line into quantity, unit, and name separately.
   Normalize units to standard abbreviations (tbsp, tsp, cup, oz, g, ml, lb).
   If a unit is ambiguous or colloquial (e.g. "a splash", "a good glug"), keep
   it as given in the "notes" field and leave "unit" null.
4. Reconstruct instructions as a clean, numbered sequence even if the source
   rambles or is out of order — infer logical cooking order from context. For
   each step, if the text states or clearly implies a single cooking duration
   (e.g. "bake for 20 minutes", "simmer 1 hour"), set that step's
   "duration_seconds" to that time in total seconds; otherwise set it null.
   Never guess a duration that isn't stated.
5. If title is not explicitly stated, generate a concise, descriptive title
   from the dish being made — never a generic phrase like "Recipe."
6. Populate the "confidence" object honestly:
   - "ingredients_complete": false if items seem missing (e.g. instructions
     reference an ingredient never listed)
   - "instructions_complete": false if steps seem to skip logical stages
   - List any fields you could not determine in "missing_fields"
   - Lower "overall" confidence when the text is sparse or ambiguous
7. If the source text contains no discernible recipe at all, return the JSON
   with empty ingredients/instructions arrays and "overall": 0.

Input will be provided as:
ARTICLE: <text>"""

GENERIC_RECIPE_SYSTEM_PROMPT = """\
Generate a standard, reliable recipe for the dish named below, incorporating
any distinguishing details provided. This is NOT based on a specific source —
generate from general culinary knowledge. Keep it approachable and correct,
not overly creative. Set "source_type": "generated" and set
"confidence.overall" to reflect that this is a generic reference recipe, not
an extracted one. For each step with a clear cooking duration (e.g. "bake for
20 minutes"), set that step's "duration_seconds" to that time in total seconds;
otherwise set it null."""

# The recipe JSON shape we hand the model (referenced as "the schema provided").
_RECIPE_SCHEMA_HINT = """\
Respond with ONLY a JSON object of this shape:
{
  "title": "string",
  "servings": {"amount": number|null, "unit": string|null},
  "prep_time_minutes": number|null,
  "cook_time_minutes": number|null,
  "total_time_minutes": number|null,
  "ingredients": [
    {"quantity": number|null, "unit": string|null, "name": "string", "notes": string|null}
  ],
  "instructions": [
    {"step_number": number, "text": "string", "duration_seconds": number|null}
  ],
  "confidence": {
    "overall": number,
    "ingredients_complete": boolean,
    "instructions_complete": boolean,
    "missing_fields": ["string"]
  }
}"""


# --------------------------------------------------------------------------- #
# Client
# --------------------------------------------------------------------------- #


def _client() -> OpenAI:
    if not config.OPENAI_API_KEY:
        raise LLMError("missing_api_key", "OPENAI_API_KEY is not set")
    return OpenAI(api_key=config.OPENAI_API_KEY)


def _raw_call(system: str, user: str, schema_model: Type[T]) -> str:
    """One Chat Completions call using OpenAI Structured Outputs.

    The response is constrained to `schema_model`'s JSON schema, so the "output
    ONLY valid JSON" rule in the prompts is enforced at the API level.
    `reasoning_effort` is "none" (no reasoning tokens) to keep cost/latency low
    for this simple reformatting task.

    Returns the raw JSON string (not the parsed object) so the existing
    parse/validate + retry-once logic below runs unchanged.
    """
    try:
        completion = _client().chat.completions.parse(
            model=config.OPENAI_MODEL,
            reasoning_effort="none",
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            response_format=schema_model,
        )
    except OpenAIError as exc:
        raise LLMError("llm_api_error", str(exc)) from exc

    message = completion.choices[0].message
    if message.refusal:
        raise LLMError("llm_refusal", message.refusal)
    return (message.content or "").strip()


def _strip_fences(text: str) -> str:
    """Defensive: strip ```json fences if the model adds them despite the prompt."""
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else t[3:]
        if t.rstrip().endswith("```"):
            t = t.rstrip()[:-3]
    return t.strip()


def _parse_and_validate(text: str, model: Type[T]) -> T:
    return model.model_validate_json(_strip_fences(text))


def _call_validated(system: str, user: str, model: Type[T]) -> T:
    """Call, validate, and retry exactly once on malformed output (CLAUDE.md §5)."""
    text = _raw_call(system, user, model)
    try:
        return _parse_and_validate(text, model)
    except (ValidationError, json.JSONDecodeError, ValueError):
        # One corrective retry, echoing the bad output back.
        corrective = (
            f"{user}\n\n"
            "Your previous response was not valid JSON matching the required "
            "schema. Respond again with ONLY the JSON object, no prose, no "
            "markdown fences.\n\n"
            f"Previous (invalid) response:\n{text}"
        )
        retry_text = _raw_call(system, corrective, model)
        try:
            return _parse_and_validate(retry_text, model)
        except (ValidationError, json.JSONDecodeError, ValueError) as exc:
            raise LLMError(
                "invalid_llm_output",
                f"model output failed schema validation after one retry: {exc}",
            ) from exc


# --------------------------------------------------------------------------- #
# Public pipeline steps
# --------------------------------------------------------------------------- #


def extract_recipe(caption: str) -> LLMRecipe:
    """Tier: caption has signal → full extraction."""
    user = f"{_RECIPE_SCHEMA_HINT}\n\nCAPTION: {caption}"
    return _call_validated(EXTRACTION_SYSTEM_PROMPT, user, LLMRecipe)


def extract_recipe_from_article(text: str) -> LLMRecipe:
    """Web tier: no JSON-LD → extract from readability-cleaned article text.

    Reuses the same schema, validation, and retry-once path as the caption
    extractor; only the prompt framing differs ("ARTICLE" vs "CAPTION")."""
    user = f"{_RECIPE_SCHEMA_HINT}\n\nARTICLE: {text}"
    return _call_validated(ARTICLE_EXTRACTION_SYSTEM_PROMPT, user, LLMRecipe)


def identify_dish(caption: str) -> DishIdentification:
    """Fallback step 1: identify the dish."""
    user = f"CAPTION: {caption}"
    return _call_validated(DISH_ID_SYSTEM_PROMPT, user, DishIdentification)


def _ingredient_line(ing: Ingredient) -> str:
    """Render one extracted ingredient back to a readable line for the prompt."""
    parts: List[str] = []
    if ing.quantity is not None:
        q = ing.quantity
        parts.append(str(int(q)) if float(q).is_integer() else str(q))
    if ing.unit:
        parts.append(ing.unit)
    parts.append(ing.name)
    line = " ".join(parts)
    if ing.notes:
        line += f" ({ing.notes})"
    return f"- {line}"


def generate_generic_recipe(
    dish: DishIdentification,
    known_ingredients: Optional[List[Ingredient]] = None,
) -> LLMRecipe:
    """Fallback step 2: generate a generic recipe for the identified dish.

    When `known_ingredients` is passed (the "caption gave us ingredients but no
    method" case in the orchestrator), the real ingredient list is handed to the
    model so it writes a method for *those exact* ingredients instead of
    inventing a dish from scratch. Called with no `known_ingredients`, behaviour
    is identical to before (the existing fully-generated fallback path).
    """
    details = ", ".join(dish.distinguishing_details) or "none"
    user = (
        f"{_RECIPE_SCHEMA_HINT}\n\n"
        f"Dish: {dish.dish_name}\n"
        f"Cuisine: {dish.cuisine or 'unspecified'}\n"
        f"Distinguishing details: {details}"
    )
    if known_ingredients:
        lines = "\n".join(_ingredient_line(i) for i in known_ingredients)
        user += (
            "\n\nThese ingredients were already extracted from the original "
            "recipe. Write the method for these exact ingredients (do not add or "
            "remove ingredients), and return this same ingredient list unchanged "
            "in your JSON:\n" + lines
        )
    return _call_validated(GENERIC_RECIPE_SYSTEM_PROMPT, user, LLMRecipe)
