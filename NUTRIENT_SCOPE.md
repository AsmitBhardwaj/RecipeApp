# NUTRIENT_SCOPE.md

Scoping for **LLM-estimated nutrition** (rough calories/protein/carbs/fat per
recipe), surfaced on Recipe Detail and later a weekly Meal Plan summary.
Nutrients belong to the recipe → live in the shared recipe cache (keyed by
`canonical_video_id`), not per-user.

Discovery only. No code changed. Findings from `main` @ `9fc8813`, real cached
data, and the 30-URL extraction probe (`probe/results.json`).

**Verdict up front:** Worth building, but *only* if framed and labeled as a rough
estimate with graceful degradation. The structured ingredient data is genuinely
good enough for a roughly-sound estimate on the **majority** of recipes (~75%
have real quantities), and it piggybacks on the existing extraction LLM call for
near-zero added cost/latency. **The real weak spot is missing servings, not
missing ingredients** — that limits reliable *per-serving* numbers, and ~25% of
recipes have no usable quantities at all. Build it, but design for "we don't
have enough to estimate this one."

---

## 1. Data quality reality check (the deciding question) — HONEST READ

I could pull only **1 recipe from the local `recipes.db`** (it's the dev SQLite;
production is Postgres on Railway and is not reachable from here — no
`DATABASE_URL` locally). But that one recipe plus the 30-URL extraction probe
give a real, representative picture, because **ingredient structure is enforced
by the pipeline, not left to chance.**

**Ingredients ARE structured, not free-text blobs.** Every ingredient is a
Pydantic `Ingredient{quantity: float?, unit: str?, name: str, notes: str?}`
(`app/models.py:28`), and the LLM is bound to that schema via OpenAI Structured
Outputs. The one real cached recipe (a caption-extracted "Gratin dauphinois"):
```
{"quantity": 1.5, "unit": "kg",     "name": "potatoes"}
{"quantity": 400, "unit": "g",      "name": "milk"}
{"quantity": 500, "unit": "g",      "name": "heavy cream"}
{"quantity": 2,   "unit": "cloves", "name": "garlic"}
{"quantity": null,"unit": null,     "name": "thyme"}      ← real: no qty given
```
That is exactly the shape you want for nutrient estimation: amount + unit +
ingredient, parsed. This is *categorically better* than the free-text lists a
lot of recipe apps have to work with.

**How often are quantities actually present?** From the probe (29 of 30 captions
extracted successfully):
- **22/29 (76%) have real quantities** (`has_quantities: true`), e.g.
  "400g boneless chicken thigh", "20g butter", "300-400g pasta", "50 ml milk",
  "3 tbsp mayo". These are directly LLM-estimable to a roughly-sound calorie/macro
  figure.
- **7/29 (~24%) have no usable quantities** — e.g. a caption that is literally
  "Cooking pt. 27 — COMMENT 'YUM' for chicken marinate #chickenbowl". For these,
  a nutrient estimate is effectively a guess with no basis. (These also tend to
  be the recipes that fall to the `generated` fallback, where the *method* is
  invented anyway.)
- **Bonus signal: 6/29 captions ALREADY contain creator-stated nutrition**
  (per-serving calories/protein/carbs/fat), e.g. "Macros (per serving): Calories
  380, Protein 38g, Carbs 3g, Fat 22g". For these you can *extract* rather than
  estimate — strictly better data, free.

**The genuine limitation — servings.** Per-serving macros need a serving count,
and servings are frequently null (the one cached recipe has
`servings: {amount: null, unit: null}`). Without servings you can honestly give
only a **per-recipe total**, or you must also LLM-estimate the serving count
(another approximation stacked on the first). This is the single biggest honesty
issue, more than ingredient quality.

**Bottom line for #1:** The data supports a *rough, clearly-labeled* estimate for
~three-quarters of recipes. It does **not** support precise or per-serving
numbers universally. This is a "≈" feature, not a nutrition-label feature — build
it as such (round hard, show a range or "estimated," and suppress it entirely
when quantities are absent rather than printing a fabricated number).

---

## 2. Where extraction happens & one call vs. two

Extraction lives in `app/pipeline/llm.py`:
- `extract_recipe(caption)` (`llm.py:238`) — caption path.
- `extract_recipe_from_article(text)` (`llm.py:244`) — blog path.
- `generate_generic_recipe(...)` (`llm.py:274`) — fallback path.

All three funnel through `_call_validated → _raw_call` (`llm.py:165`), which uses
**OpenAI Structured Outputs**: `chat.completions.parse(..., response_format=LLMRecipe)`
(`llm.py:177`). The output is *schema-bound to the `LLMRecipe` Pydantic model*
(`app/models.py:58`). The prompt also hands the model an explicit shape hint,
`_RECIPE_SCHEMA_HINT` (`llm.py:131`).

**This is a cheap ONE-field addition to the SAME call — no second round-trip.**
Because the response is constrained to `LLMRecipe`, adding a `nutrition` field to
that model automatically makes the model emit it. The change is:
1. Add `nutrition: Nutrition | None` (a small typed submodel) to `LLMRecipe`.
2. Add the field to `_RECIPE_SCHEMA_HINT`.
3. Add one prompt rule to each system prompt, e.g. *"Estimate approximate
   nutrition (calories, protein_g, carbs_g, fat_g) for the whole recipe from the
   ingredient list; this is a rough approximation, not a measured value. If the
   caption already states nutrition, use those figures. If there are too few
   quantities to estimate, set nutrition to null."*

Every path (caption / article / generated) inherits it for free since they share
`LLMRecipe`. One caveat worth noting: extraction prompt **Rule 2** currently says
"Never invent ingredients, quantities, or steps." Nutrition is *inherently*
estimated, so the new instruction must carve out an explicit exception for the
nutrition field, or the two rules read as contradictory. Minor prompt wording,
but do it deliberately.

A **separate** nutrition-only call is possible (and is what you'd use for lazy
backfill of already-cached recipes, see #4) but is not needed for new
extractions — piggybacking is strictly cheaper and adds no latency.

---

## 3. Storage — flexible JSON, zero migration

The cached recipe is stored as an **opaque JSON blob**: `recipes.data` is a
`Text` column holding `Recipe.model_dump_json()` (`app/db.py:58-64`,
`db.py:267`). Only `recipe_id` and `canonical_video_id` are promoted to real
columns. So a new field needs **no schema migration** on either SQLite or
Postgres.

Even better: **the field already exists.** `Recipe` carries
`nutrition: Optional[dict] = None` right now (`app/models.py:108`), added as a
deliberate future-proofing placeholder (CLAUDE.md §8). Today it's always null.
To ship, you'd tighten that `dict` into a typed `Nutrition` submodel (calories,
protein_g, carbs_g, fat_g, plus maybe `basis: "estimated"|"creator_stated"` and
`per: "recipe"|"serving"`) — but that's a model refinement, not a migration.
Old cached rows without the key decode fine (the field is optional/defaulted).

---

## 4. Backfill

**Count today:** local dev cache = **1 recipe**. Production Postgres is not
reachable from this machine, so I can't give the real number — but per the repo's
own status (pre-launch / TestFlight stage, no launch yet), the production cache is
almost certainly **small: dozens to low hundreds, not thousands.**

**Approach:** new recipes get nutrition for free via #2 going forward. Existing
cached recipes have `nutrition: null` and need backfilling. Two options:
- **Lazy-on-first-view** — when a recipe with null nutrition is fetched, kick off
  a cheap *nutrition-only* LLM call (ingredients → macros) and write it back to
  the cache. Pro: no batch infra, only pays for recipes anyone actually opens.
  Con: needs a small new code path (a nutrition-only prompt + a write-back), and
  the first viewer sees it appear a beat late.
- **One-time batch pass** — a script iterating the `recipes` table calling the
  same nutrition-only path. Pro: dead simple, uniform, done once. Given the tiny
  volume, this is the pragmatic choice.

**Cost/time:** a nutrition-only call is *cheaper* than a full extraction (tiny
output). At the documented ~$0.002–0.005 per full extraction, a nutrition-only
call is well under that. Backfilling even **500 recipes ≈ $1–2.50 and a few
minutes**; 100 recipes is pocket change. Either approach is trivial at this
scale. **Recommendation:** ship piggybacked-on-extraction for new recipes, add a
one-time batch script for whatever's already cached. Skip lazy backfill unless
the cache turns out to be large.

---

## 5. iOS side

**`RecipeDetailView`** (`ios/RecipeApp/Views/Main/RecipeDetailView.swift`) is a
clean, composed SwiftUI screen: `body` stacks `header`, `metaRow`,
`ingredientsSection`, `instructionsSection`, etc. (`:37-52`). Adding a
`nutritionSection` is **one new computed view + one line in `body`** — realistically
~30–50 lines (a `tornEdgeCard`-style row of four figures, matching the existing
`metaRow` idiom, hidden when nutrition is nil). Low risk, no architectural change.

**The `Recipe` Swift model needs a real (small) change.** Right now the Swift
`Recipe` (`ios/RecipeKit/Sources/RecipeKit/Models/Recipe.swift`) **deliberately
omits** the nutrition field — there's an explicit comment at `Recipe.swift:44-48`
saying `Codable` ignores the unknown `nutrition` key and a typed model will be
added "when the nutrition feature actually lands." So:
- Add a `Nutrition: Codable` struct (4 optional numbers + basis/per enums).
- Add `nutrition: Nutrition?` + its `CodingKey` to `Recipe`.
- **Friction point:** `Recipe` uses an explicit `public init` with all stored
  properties (`:52-82`), and the app constructs `Recipe` directly for mock/sample
  data (`.spicyNoodles`, `.margheritaPizza`, previews, etc.). Adding a stored
  `let` means updating that initializer and **every call site** — unless you give
  the new init param a default (`nutrition: Nutrition? = nil`), which keeps
  existing constructors compiling untouched. Do that to minimize churn.
- Decoding safety: unknown-key tolerance means **old cached JSON still decodes**;
  the new optional field is simply nil for pre-nutrition recipes. No data break.

**Weekly Meal Plan summary** is then pure **client-side aggregation** over
recipes the app already has (sum nutrition across the day's/week's Meal Plan
check-offs or Cook Mode completions). No backend work, no extra LLM calls — just
a computed view over synced data. (Only real caveat: summing is only honest when
the underlying recipes actually have nutrition and comparable `per` basis — show
"based on N of M recipes" when some are missing.)

---

## 6. Cost & latency

- **Piggybacked on extraction (#2): negligible.** No extra round-trip. Output
  grows by ~4 numbers (tens of tokens); input grows by a few prompt lines.
  `reasoning_effort` is already `"none"`, so no thinking-token cost. Net effect
  is a **sub-cent delta per extraction and no meaningful latency change** — the
  user is already waiting on this one call.
- **A separate per-recipe call would roughly double request overhead and add a
  full round-trip of latency** — avoid for the live path; reserve it only for
  one-off backfill of already-cached recipes (#4), where latency doesn't matter.
- **Weekly summary: $0** — client-side math over already-synced data.

**Conclusion:** if it rides the existing extraction call, nutrition estimation is
effectively free on cost and latency. The only real spend is the one-time
backfill of the existing cache, which is a few dollars at most at this scale.

---

## Summary

| Question | Answer |
|---|---|
| 1. Data good enough? | **Mostly yes** — ingredients are structured (amount+unit+name), 76% have real quantities, some captions even state macros. **But** servings are often missing (limits per-serving accuracy) and ~24% have no quantities. Ship as a labeled *rough estimate* that degrades gracefully. |
| 2. One call or two? | **One** — add a `nutrition` field to the schema-bound `LLMRecipe`; all extraction paths inherit it. Carve out extraction Rule 2's "never invent" for this field. |
| 3. Migration? | **None.** Recipe is an opaque JSON blob and already has a null `nutrition` field (`models.py:108`). |
| 4. Backfill | Prod count unknown (Postgres not reachable), but small at this stage. New recipes free via #2; one-time batch script for existing (≈$1–2.50 for 500). |
| 5. iOS work | `RecipeDetailView`: ~one new section. `Recipe.swift`: add a typed `Nutrition` + optional field (default-nil init param to avoid touching call sites). Old cached data decodes fine. |
| 6. Cost/latency | **Piggybacked = negligible** (sub-cent, no extra round-trip). Separate call = avoid. Weekly summary = client-side, free. |

**Overall:** technically cheap and low-risk; the honest gating factor is *data
completeness (servings + the quantity-less 25%)*, not architecture. Build it with
"estimated" framing and null-handling from day one, not UI-first.
