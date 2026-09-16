# PANTRY_SCOPE.md — Pantry-Suggestion Feature (scoping, pre-code)

Status: **proposal for review. No implementation code written yet.**
Depends on: `app/ingredient_matching.py` (merged to main, commit `21dba0b`).

"Suggest recipes I can make from what's in my pantry." Primary path is a search
over the shared recipe cache by `normalized_name` overlap; a generation fallback
fills in only when the cache returns too few matches.

---

## 0. Scope check (CLAUDE.md §2 / §8) — read first

CLAUDE.md lists two "later, out of MVP" items this feature overlaps, so per §8 I'm
flagging rather than silently expanding scope:

- **"AI recipe generation from scratch (…'by ingredients') — later."** The
  generation fallback below is by-ingredients generation. It reuses the existing
  extraction schema + validation + the `source_type: "generated"` precedent, so
  it's the "cheap to add later" case §2 anticipated — but it is still past MVP.
- **"Suggested recipes from other users' vaults — later, needs real usage data
  first."** Cache-search draws from the shared, cross-user recipe cache, which is
  adjacent to this. We are *not* exposing other users' personal library/join
  data — only the de-identified shared recipe rows (keyed by
  `canonical_video_id`) that the cache already pools. Worth an explicit product
  nod before build.

The project has already moved well past strict MVP (auth, sync, Cook Mode,
nutrition, Kitchen/pantry), so this is consistent with direction — just calling
it out so the expansion is a decision, not an accident. **Everything below assumes
you confirm we're building this now.**

---

## 1. What already exists (grounding)

- **`normalize_ingredient_name()` / `ingredients_match()`** (`app/ingredient_matching.py`):
  canonical token per ingredient + word-boundary matching. `save_recipe` stamps
  `normalized_name` onto every cached recipe's ingredients regardless of source.
  A backfill script exists for pre-feature rows.
- **Pantry items** (`PantryItem`: `{id, name, dateAdded}`, name stored verbatim)
  already sync to the backend as the `pantry_items` collection in `sync_items`
  (payload opaque to the server). So **the server can already read a user's
  pantry** via a `sync_items` query — no new ingestion path needed.
- **Recipe cache**: `recipes` table, `data` = opaque JSON blob keyed by
  `recipe_id` / `canonical_video_id`. `normalized_name` lives *inside* that blob.
  **There is no column or index on it today** — this is the central design
  decision in §3.
- **Generated-recipe precedent**:
  - Backend already force-nulls nutrition for any `source_type == "generated"`
    recipe at the assembly chokepoint (`orchestrator.py:54–60`). Our fallback
    inherits this automatically.
  - iOS `GeneratedBadge` component exists but is intentionally **not called**
    (CLAUDE.md §5). This feature revives it for fallback results only.
  - iOS `nutritionSection` renders only `if let nutrition` → nil shows nothing.
- **API conventions**: `/v1/*`, `APIRouter(prefix="/v1")`, account-scoped routes
  use `Depends(current_user)` (JWT), all behind the app-key middleware gate +
  per-user/per-IP rate limit on expensive paths.

---

## 2. Proposed API endpoint

Account-scoped, same conventions as `sync.py`.

```
POST /v1/pantry/suggestions
  Auth:    current_user (JWT) + app-key middleware + rate limit
  Body:    {
             "limit": 20,                 // optional, default 20, cap 50
             "pantry_override": ["egg","spinach"]  // optional; default =
                                          //   server reads user's pantry_items
             "allow_generation": true     // optional, default true
           }
  Returns: {
             "matches": [ SuggestionResult, ... ],   // cache-search, ranked
             "generated": [ SuggestionResult, ... ], // fallback, only if sparse
             "pantry_used": ["egg","spinach", ...],  // normalized, for UI echo
             "counts": { "cache": N, "generated": M }
           }

SuggestionResult = {
  "recipe": Recipe,          // full cached Recipe shape (generated ones too)
  "match": {
    "have":    ["egg","spinach"],        // pantry ⋂ recipe (normalized)
    "missing": ["feta","olive oil"],     // recipe ingredients not in pantry
    "have_count": 2, "total_count": 6,
    "coverage": 0.33,                    // have / total
    "score": 0.71                        // ranking score, see §3
  }
}
```

Design points:
- **POST, not GET**: pantry list can be long and we may pass an override set;
  also avoids caching a per-user result at the CDN/proxy.
- Server reads pantry from `sync_items` (collection `pantry_items`) by default so
  the client doesn't re-send it; `pantry_override` supports a "what if I had X"
  UI later without an API change.
- `matches` and `generated` are **separate arrays** so the client can badge and
  order them differently without inspecting `source_type` heuristically.
- Rate-limited like `/v1/jobs` (this can trigger LLM generation).

---

## 3. Match / ranking algorithm (the core)

### 3a. The cache-scan problem — decision needed

`normalized_name` is inside the opaque `data` JSON with no index. Options:

| Option | How | Cost | Verdict |
|---|---|---|---|
| **A. Full scan + parse** | Load every `recipes.data`, parse, match in Python | O(all recipes) per request | Fine at hundreds–low-thousands of recipes; **propose for v1** given current cache size, revisit with metrics |
| **B. Inverted index table** | New `recipe_ingredients(normalized_name, recipe_id)` table, populated in `save_recipe` + backfill | One-time write cost, O(pantry) reads | Correct long-term; **defer to v1.1** once cache is large |
| C. Postgres JSON/GIN or FTS | Index into the JSON blob | DB-specific (sqlite dev vs pg prod diverge) | Rejected — breaks the sqlite/pg parity the storage layer deliberately keeps |

**Recommendation:** ship **A** in v1 behind a single `find_pantry_matches()`
function, with the query isolated so swapping in **B** later is a drop-in. Track
scan latency from day one (CLAUDE.md §7 mandates cost/perf metrics).

### 3b. Matching
For each cached recipe, for each pantry item, reuse `ingredients_match(pantry_item,
ingredient.normalized_name)` (word-boundary, already handles the "egg" ⊄ "veggies"
case). Produce `have` / `missing` / `have_count` / `total_count`.

Filter: drop recipes below a floor (e.g. `have_count < 2` **and** `coverage < 0.3`)
so a single "salt" match doesn't surface everything.

### 3c. Ranking score
Rank by a blend, not raw coverage (coverage alone over-favors 2-ingredient recipes):

```
score = 0.6 * coverage
      + 0.3 * min(have_count / 5, 1.0)      // reward absolute overlap
      + 0.1 * recipe.confidence.overall     // prefer well-extracted recipes
```
Tie-break: higher `have_count`, then fewer `missing`. Exact weights are a tuning
knob, not load-bearing.

### 3d. Dish-level dedup (in scope for this feature)
Same dish from N source videos = N cache rows (keyed per `canonical_video_id`), so
naive results show five near-identical "Marry Me Chicken." Before ranking, cluster
and keep one representative per dish cluster:

- **Cluster key (v1, cheap):** normalized title similarity + ingredient-set
  Jaccard over `normalized_name`. Two recipes merge if
  `title_similar AND jaccard(ingredients) ≥ ~0.6`.
- **Representative:** highest `confidence.overall`, tie-break newest / has-image.
- Keep it a **separate `dedup_suggestions()` stage** between match and rank, so it
  can be tuned or reused by other surfaces later.
- Explicitly *not* full recipe de-duplication across the whole cache (that's a
  bigger data-model change) — only within a single suggestion response.

### 3e. Generation fallback (only when sparse)
If `len(matches) < threshold` (e.g. 5) **and** `allow_generation`:
- Reuse the existing dish-ID → generic-recipe generators (`llm.generate_generic_recipe`)
  seeded by the strongest pantry items, to synthesize a few by-ingredients recipes.
- Emit them with **`source_type: "generated"`** → the existing chokepoint nulls
  nutrition automatically; no new suppression code server-side.
- These are cached like any recipe (idempotency still applies) but flagged so the
  client can badge them.
- **Do not** generate when cache matches are already plentiful — cost guardrail.

---

## 4. iOS wiring — badge + nutrition suppression

The backend already does the hard part; iOS changes are mostly presentation.

- **Badge (revive `GeneratedBadge`):** in the suggestion list/detail, render
  `GeneratedBadge` when `recipe.isGenerated` (the flag already exists in
  `Recipe+Display.swift`). This is the "lower-trust" label. Scoped to the
  **suggestions surface only** — the main recipe list keeps its current no-badge
  behavior (CLAUDE.md §5) unless you decide otherwise. One consideration to
  confirm: badge copy for pantry-generated ("Suggested recipe" vs "Generated
  recipe").
- **Nutrition suppression:** no new client logic. Generated recipes arrive with
  `nutrition == nil` (backend chokepoint), and `nutritionSection` already renders
  nothing for nil. Suppression is therefore *enforced server-side and inherited*,
  which is the correct place for it — the client can't accidentally show macros
  for a generated recipe.
- **Match context UI (new, small):** a "you have 2 of 6" / missing-ingredients
  chip driven by the `match` object. Read-only display of API data.
- New `PantrySuggestionsView` + a provider method on the API client
  (`APIRecipeProvider`) calling `POST /v1/pantry/suggestions`. Entry point likely
  from the Kitchen tab (where the pantry already lives).

---

## 5. v1 scope vs deferred

### In v1
- `POST /v1/pantry/suggestions` (auth + app-key + rate-limited).
- Server reads pantry from `sync_items` (`pantry_items`); `pantry_override` supported.
- Cache-search via **full-scan option A**, isolated behind `find_pantry_matches()`.
- Word-boundary matching reusing `ingredient_matching`.
- Blended ranking (§3c) with a match floor.
- **Dish-level dedup within a response** (§3d).
- Generation fallback on sparse results, `source_type: "generated"`, nutrition
  auto-suppressed, results cached.
- iOS: `PantrySuggestionsView`, revived `GeneratedBadge` on suggestions, match
  context chip, Kitchen-tab entry point.
- Metrics: scan latency, cache-hit vs generation rate, avg matches per request.

### Deferred (v1.1+)
- **Inverted-index table (option B)** — swap in when scan latency/metrics justify.
- Cross-request / whole-cache dedup and canonical dish identity.
- "What can I *almost* make" (missing ≤1) as a distinct ranked bucket.
- Substitution awareness ("has butter, recipe wants ghee").
- Quantity/unit awareness (pantry is name-only today, by design).
- Pantry-item disambiguation ("pepper" → black vs bell) — the known accepted
  limitation from `ingredient_matching.py`.
- Personalization/learning from which suggestions the user actually cooks.
- Surfacing *other users'* library recipes specifically (needs the §0 product
  decision + usage data).

---

## 6. Open questions — ANSWERED (2026-09-16)
1. **Scope expansion confirmed** — proceed.
2. **Badge copy: "Suggested recipe"** (not "Generated recipe"). Kept distinct
   from the existing paste-fallback generated badge: different trust contexts,
   even though both suppress nutrition identically.
3. **Sparse-to-generation threshold: fewer than 2 cache matches.** Generation
   fallback defaults **ON** for v1.
4. **Entry point: Kitchen tab only** for v1 — no Recipes-tab affordance.

## 7. Implementation sequencing (agreed)
Serial, backend fully verified before any iOS:
- **Pass 1 (backend):** matching/ranking/dedup + generation-fallback wiring +
  `POST /v1/pantry/suggestions` + Python tests. **Gate: full `pytest` green AND
  `swift test` green before Pass 2.**
- **Pass 2 (iOS):** `PantrySuggestionsView`, revived `GeneratedBadge` ("Suggested
  recipe") on this surface only, matches/generated sections, Kitchen-tab entry.
  Not started without explicit go-ahead.
