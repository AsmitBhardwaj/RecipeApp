# Budget Meal Planning — Feature Plan

**Status:** Planning. The three open questions and the C1 sequencing are now
**SETTLED** (see [§4](#4-settled-decisions-was-open-questions) and
[C1](#complications), locked 2026-09-04). **Do not write feature code until the
[§6.1](#61-hard-prerequisites-close-these-before-any-implementation) blocker is
cleared** — as of 2026-09-04 that blocker is **NOT fully clear** (see the dated
verification note there). This doc is grounded in the code on `main`; "today"
means verified against the repo, not assumed.

**Working name:** "budget meal planning." The persistent on-hand ingredient list
is named **"On Hand"** everywhere (UI copy, models, code) — deliberately **not**
"Pantry," which already exists as a `GroceryCategory` aisle name (settled, was C8).

**Audience:** whoever implements this (iOS + backend).

**Why this lives in `docs/` and not `CLAUDE.md`:** root `CLAUDE.md` §2 is
explicitly "MVP scope — build this first, nothing more," so a large feature spec
does not belong inline there. The repo had no planning-doc home: no `docs/`
folder, and `TODO.md` is *referenced* by `app/pipeline/fetch.py` comments but
**does not exist** (dangling ref). This introduces `docs/` for forward-looking
specs and keeps `CLAUDE.md` as the source of truth for what is built. (Minor
cleanup, separate: create that `TODO.md` or repoint the `fetch.py` comments here.)

---

## 1. Feature overview

A budget- and On-Hand-aware planning flow. The user provides:

- a **budget**,
- their **location** (for regional cost calibration — no store-accurate pricing),
- and their **On Hand list**: a persistent, running list of ingredients they
  already have, maintained over time (not re-entered each session).

The app plans healthy meals within that budget and produces a grocery list of
**only what's missing** (planned-recipe ingredients minus On Hand).

### Settled product decisions (not open for debate)

1. **Cost estimation:** no real-time or per-store pricing. Use location to apply a
   **regional cost multiplier** over a baseline estimated basket cost. Always
   presented as a labeled estimate, never store-accurate.
2. **Meal sourcing:** **v1 is generation-first** (see [C1](#complications) — this
   was revised from the original cache-first framing). `POST /v1/plan` always
   generates via budget/On-Hand-aware LLM generation; cache-first querying is a
   usage-gated fast-follow, not a v1 concern.
3. **On Hand is persistent per-user state** the user maintains (add/remove).
   **v1 is add/remove only.** Auto-decrementing when a recipe is cooked, or
   reconciling against Grocery List check-offs, is **out of scope for v1** (v2) —
   leave room for it, don't design it now.

---

## 2. What already exists (grounding)

| Area | Where | Behavior today |
|---|---|---|
| Shared recipe cache | `app/db.py` `get_recipe_by_video_id`, `get_recipe`; `orchestrator.py` step 2 | **Point lookup by exact key** (`canonical_video_id` UNIQUE, or `recipe_id`). Shared across ALL users. **No search/query by dish, ingredients, cost, or health.** |
| LLM generation | `app/pipeline/llm.py` `generate_generic_recipe(dish, known_ingredients=)` | Generates one recipe for a *named dish*. **Not budget- or On-Hand-aware.** OpenAI Structured Outputs against `LLMRecipe`; `reasoning_effort="none"`; validate + one retry. |
| Recipe model | `app/models.py` `Recipe` | Has nullable **`nutrition: Optional[dict]`** + `transcript` placeholders (the "cheap additive field, no migration" convention, CLAUDE.md §8). **No cost field; `nutrition` is never populated today.** |
| Persistence layer | `app/db.py` | SQLAlchemy Core, dialect-agnostic (SQLite local / Postgres prod). Tables on one `MetaData`; `init_db()` = `metadata.create_all()`. Dialect-specific upserts via `_insert()`. |
| Generic per-user sync | `app/db.py` `sync_items` + `sync_state`, `SYNC_COLLECTIONS`; `app/sync.py` | **One generic table for every synced collection.** Server treats `payload` as **opaque JSON** (last-writer-wins by `updated_at`, monotonic `seq`). Allowlist today: `library, meal_plan, grocery_check, grocery_manual, cookbook, cookbook_membership`. |
| Meal Plan (iOS) | `Views/Main/MealPlanView.swift`, `MealPlanModel.swift`, `RecipeKit/.../MealPlanEntry.swift`, `MealSlot.swift`, `Storage/MealPlanStore.swift` | 7-day view, **4 slots/day** (`breakfast, lunch, snacks, dinner`), assignment picker. **Local-first** (App Group) + synced as `meal_plan`. Entries **denormalize** `recipeTitle`/`recipeImageURL` (no server "list my recipes" endpoint). |
| Grocery List (iOS) | `Views/Main/GroceryListView.swift`, `GroceryListModel.swift`, `RecipeKit/.../GroceryList.swift` | **Fully functional** (see [C7](#complications)). Pure `GroceryAggregator.aggregate(recipes:)` merges by (name, unit) — **no unit conversion**. `GroceryCategorizer` offline keyword heuristic. Derived live from the plan for a day/week; `grocery_check` + `grocery_manual` persist ticks + manual items. |
| Sync wiring | `RecipeKit/.../Sync/SyncModels.swift` (`SyncCollection` enum), `Sync/SyncPayloads.swift` (codecs), server `SYNC_COLLECTIONS` | New synced collection = `SyncCollection` case + payload codec + local store (client) **and** the name added to server `SYNC_COLLECTIONS`. **No new SQL table.** |
| Tab shell | `Views/Main/MainTabView.swift` | Three tabs: **Recipes**, **Meal Plan**, **Grocery List**. Account via toolbar. (Its "Grocery List is a coming-soon shell" header comment is **stale** — see [C7](#complications).) |

**Naming collision handled:** "Pantry" already exists as a `GroceryCategory`
display name (a shopping *aisle*). The new persistent list is therefore named
**"On Hand"** to avoid overloading it. "Meal Plan" is also a shipped tab — the new
flow lives *inside* it as a mode (see [§4 OQ1](#oq1-naming--placement--settled-b)).

---

## 3. Architecture

### 3.1 Backend — data model

**On Hand** is a **new `on_hand` sync collection** (settled, OQ3 Option A) — it
follows the exact `meal_plan`/`grocery_manual` precedent: a per-user, add/remove
list that gets last-writer-wins convergence and cross-device sync **for free** via
`sync_items`. **No new SQL table.** The server sees `payload` as opaque JSON, so
the planner can't `SELECT` On Hand contents — the **client sends the On Hand
snapshot in the plan request** (fine; the client is its source of truth anyway).

**Budget-plan result** is **transient** (settled, OQ3): computed on request,
returned, and the recipes the user accepts are **committed into the existing
`meal_plan` collection client-side**. No `budget_plan` persistence in v1.

**Additive `Recipe` fields (CLAUDE.md §8 convention)** — populated at generation
time (see [C1](#complications)), which organically builds the annotated cache a
future search layer would need:

- `baseline_cost_estimate: Optional[dict]` — e.g. `{ "amount": float, "currency":
  "USD", "basis": "llm-v1" }`. **Location-independent**; per-user cost =
  `baseline × regional_multiplier`, computed at plan time.
- Health signal — prefer populating the existing `nutrition` placeholder, or add
  `health_tags: Optional[list]`, rather than parallel state.

Honest boundary: **On Hand is genuinely new state** (its own sync collection,
planned as such). Only the per-recipe cost/health *annotations* are additive
`Recipe` fields.

### 3.2 Backend — API endpoints

- `POST /v1/plan` (new) — body: `{ budget, currency?, location, on_hand: [...],
  constraints?: { days, slots, dietary/health } }`. Returns: per-slot recipe
  (**with display snapshot** so the client renders without a vault endpoint — same
  reason `MealPlanEntry` denormalizes), per-recipe + total **estimated** cost
  (clearly labeled), and the **missing-ingredients grocery list** (planned
  ingredients minus On Hand). App-key gated + rate-limited like `/v1/jobs` — this
  fans out to multiple LLM generations, so **guard cost hard**.
- **On Hand:** no new endpoints — it flows through existing `/v1/sync/*` push/pull.
  Only add `on_hand` to the server `SYNC_COLLECTIONS` allowlist.
- **Commit accepted recipes into `meal_plan` client-side** (create
  `MealPlanEntry`s) — no `/v1/plan/commit` endpoint needed.

### 3.3 Meal sourcing — generation-first (v1)

Per the settled C1 revision, **v1 does not attempt a constraint-based cache
lookup.** For each meal slot, `POST /v1/plan` runs **budget/On-Hand-aware LLM
generation** (extending `generate_generic_recipe` with budget + On-Hand context
and new prompt framing). Every recipe generated this way is:

1. Tagged at generation time with `baseline_cost_estimate` + a health signal.
2. Written into the shared recipes cache, so it becomes a shared asset.

This **organically builds the annotated cache** the future cache-search layer
would need — no upfront backfill project. See [C1](#complications) for why
cache-first was deferred and what signal gates building it.

### 3.4 Cost calibration — LLM-estimated (settled)

`estimated_cost(recipe, location) = baseline_basket_cost(recipe) ×
regional_multiplier(location)`, where:

- `baseline_basket_cost` is the location-independent per-recipe estimate cached on
  the `Recipe` (§3.1), derived once at generation and reused.
- `regional_multiplier(location)` is a small **STATIC two-part table** (no LLM call,
  no external dataset in v1), where `location = (country, area_type)`:

  ```
  regional_multiplier = country_baseline(country) × area_modifier(area_type)
  ```

  `country_baseline` is a coarse cost-of-living factor vs. the US national average
  (1.0), keyed on ISO 3166-1 alpha-2; unlisted countries default to 1.0.
  `area_modifier` is `city 1.15 / suburb 1.00 / rural 0.85` (suburb = the anchor).
  Either part unset falls back to 1.0. Implemented in
  `app/pipeline/regional_cost.py`; the final multiplier is rounded to two decimals.
  Always present cost to the user as an **estimate/range**.

**Pre-ship sanity check (replaces the cancelled spike):** confirm the static
table's **ordering is sane** — a high-cost country/city (e.g. Switzerland/city)
must rank above the US suburb baseline, which must rank above a low-cost
country/rural area (e.g. India/rural), and within a country city > suburb > rural.
Covered by `RegionalMultiplierTests`/`MultiplierTableTests` in
`tests/test_budget_plan.py`. Revisit a real index only if users report the numbers
feel wrong post-launch.

### 3.5 iOS changes

- **On Hand management UI** — persistent add/remove list. New `SyncCollection`
  case `onHand` (`"on_hand"`), `OnHandItem` model + `OnHandStore` (mirror
  `GroceryManualItem` + its store), payload codec in `SyncPayloads.swift`.
  **Placement:** its own clearly-surfaced destination reachable **directly from
  Meal Plan** (one tap, not buried in Account/Settings) — On Hand is state users
  touch as often as Grocery List (settled, OQ1).
- **Plan entry + results UI** — budget + location (+ constraints) inputs inside
  Meal Plan's **"Plan on a Budget"** mode; a results screen showing planned meals,
  estimated cost, and the missing-ingredients list.
- **Grocery reuse** — "just what's missing" is `GroceryAggregator.aggregate(
  plannedRecipes)` **minus On Hand items**: a new *filter step* over an existing
  pure function (likely the cleanest reuse in the feature). Match on normalized
  name (same fuzziness the categorizer already lives with; no unit conversion).
- **Commit-to-plan** — accepted recipes become `MealPlanEntry`s in `meal_plan`, so
  the existing Meal Plan + Grocery List light up from a generated plan.
- **Location capture** — two stored signals set in onboarding (Screen 5) and
  editable in Account: **country** (a searchable ISO-country picker, stored as the
  alpha-2 code) and **area type** (City / Suburb / Rural). They live on
  `CookingPreferences` (device-local) and are sent as `country` + `area_type` on
  the budget request. CoreLocation optional/not used.

---

## 4. Settled decisions (was: open questions)

<a id="oq1-naming--placement--settled-b"></a>
### OQ1 — Naming & placement — **SETTLED: (b) a mode within Meal Plan**

The budget flow is a **mode within the existing Meal Plan tab**, via a
**segmented control**:

- **"This Week"** — today's manual day/slot recipe assignment.
- **"Plan on a Budget"** — the new budget/On-Hand flow.

Both **converge on the same `meal_plan` collection**, so a generated plan and a
manual plan produce one plan and one Grocery List. **On Hand** gets its **own
clearly-surfaced entry point reachable directly from Meal Plan** (not three taps
deep in Account/Settings) — it's touched as often as Grocery List. **Naming
(was C8):** the persistent list is **"On Hand"** everywhere (UI, models, code),
never "Pantry."

<a id="oq2-cost-multiplier--settled-llm"></a>
### OQ2 — Cost-multiplier source — **SETTLED: LLM-estimated; spike cancelled**

Since cost is always presented as a labeled estimate (never store-accurate), the
accuracy bar doesn't justify sourcing/licensing/ingesting an external
cost-of-living dataset for v1. Use **LLM-estimated** regional multipliers. The
full comparative spike is **cancelled**, replaced by the ~30-minute pre-ship
ordering sanity check in [§3.4](#34-cost-calibration--llm-estimated-settled).
Revisit a real index only on post-launch user signal.

<a id="oq3-data-model--settled-a"></a>
### OQ3 — Data model — **SETTLED: Option A (sync collection), transient plans**

On Hand is the **`on_hand` sync collection** (no new SQL table); the planner reads
it from the plan request body. Plan results are **transient** — no `budget_plan`
persistence in v1; accepted recipes are committed into `meal_plan` client-side.
(Revisit a dedicated table only if a future feature needs the *server* to reason
about On Hand without the client present.)

---

## 5. Complications found in the existing code {#complications}

Ranked by impact.

- **C1 — The shared cache is not queryable; sourcing is generation-first in v1
  (REVISED SEQUENCING, settled).** `get_recipe_by_video_id`/`get_recipe` are
  exact-key lookups; there is no way to ask the cache for "a recipe that is cheap,
  healthy, and reuses these On-Hand items." Rather than build search/index
  infrastructure upfront, **v1 ships generation-first**: `POST /v1/plan` always
  generates, and every generated recipe is tagged with `baseline_cost_estimate` +
  a health signal and written to the cache — so the annotated cache builds
  organically as a byproduct of usage. **Signal for when cache-search becomes
  worth it:** instrument and track the **rate at which the same dish/constraints
  combination recurs across plans**; build the search layer as a fast-follow once
  that recurrence rate shows real redundant generation. Cache-first is explicitly
  **out of v1 scope**, gated on usage data existing.
- **C2 — Cached recipes have no cost and no populated health/nutrition data.**
  Addressed by C1's approach: annotate at generation time going forward (no
  backfill of old cache entries in v1; they simply aren't candidates for the
  future search layer until re-generated or lazily annotated).
- **C3 — No "list my recipes / vault" backend endpoint.** Recipes live server-side
  only in the shared cache keyed by video id; the client can't ask "what recipes
  do I have" — this is *why* `MealPlanEntry` denormalizes title/image. The
  plan-result payload must likewise **carry display snapshots** (or hydrate via
  `SyncClient.recipes(ids:)`), not just ids.
- **C4 — Per-user lists are sync collections, not tables.** Meal plan, grocery
  ticks/manual items, cookbooks are all `sync_items` collections — the precedent
  On Hand follows (OQ3 Option A). Caveat, already handled: sync payloads are
  **opaque to the server**, so the planner reads On Hand from the request body.
- **C5 — Good news: "just what's missing" reuses `GroceryAggregator` directly.**
  Pure `[Recipe] -> [GroceryLineItem]`; On-Hand subtraction is a filter step, not
  a rewrite. Same edges: no unit conversion, name-normalized matching.
- **C6 — `generate_generic_recipe` is not budget/On-Hand-aware.** Needs new
  prompt(s), plus a way to emit a cost estimate + health signal alongside
  generation (the current `LLMRecipe` schema has neither field).
- **C7 — RESOLVED: the Grocery List tab is fully functional.** Verified
  2026-09-04: `GroceryListView`/`GroceryListModel` implement a complete
  live-derived shopping list (day/week scope, check-offs, manual items, sync,
  share, completion celebration). The `MainTabView` "coming-soon shell" header
  comment is **stale** and should be cleaned up; nothing is gated/hidden. The
  "just what's missing" output has a real, working grocery surface to converge on.
- **C8 — RESOLVED (settled naming):** the persistent list is **"On Hand,"** not
  "Pantry" (which is a `GroceryCategory` aisle). "Meal Plan" stays the tab; the
  budget flow is a mode inside it.

---

## 6. Getting started {#getting-started}

### 6.1 Hard prerequisites (close these before any implementation)

1. **BLOCKER — the extraction pipeline must be genuinely stable first**, not just
   "the one regression is fixed." This feature depends on the
   extraction/generation/cache pipeline; building on an unstable base conflates
   bugs and destabilizes launch.

   > **Verification status (2026-09-04): NOT fully clear.** The backend is
   > healthy — `site_blocked` graceful degradation is deployed and verified, a
   > working blog extracts fully, and `/health` is green on Postgres. **But** the
   > manual **paste-the-recipe-text fallback that `site_blocked` depends on is
   > NOT built** (no iOS paste UI, no `siteBlocked` handling in
   > `RecipeProviderError`, no backend endpoint to accept pasted text). So the
   > single most popular recipe sites (Dotdash Meredith: allrecipes, seriouseats,
   > simplyrecipes) return a clean message but have **no working import path** —
   > the core loop is broken for them with no recovery. Also, **no pre-launch
   > smoke-test checklist exists in the repo** to confirm what else is open.
   > **→ Owner's call whether this counts as "stable enough" to proceed.**
2. **Confirm what else is open on launch** — there is no tracked checklist; get a
   straight read before layering a new feature on top.

*(OQ1–OQ3 are settled — no sign-off pending there. The OQ2 cost-ordering sanity
check is a pre-ship gate inside the cost phase, not a prerequisite to starting.)*

### 6.2 Phased build plan

Order = implementation order. **Nothing starts until 6.1's blocker clears.**

**Phase 0 — Decisions (no product code)**
- OQ1/OQ2/OQ3 — **done** (settled above).
- C1 sequencing — **done**: ship **generation-first** for v1; **instrument and
  track the recurrence rate of the same dish/constraints combination across
  plans**, as the signal for when building real cache-search infrastructure is
  worth the investment. (Replaces the former "prototype/estimate C1" item.)

**Phase 1 (v1) — On Hand as persistent state**
- `on_hand` sync collection end-to-end: server `SYNC_COLLECTIONS` entry,
  `OnHandItem` model + `OnHandStore`, `SyncPayloads` codec, `SyncCollection` case.
- On Hand add/remove UI at the OQ1 placement (direct-from-Meal-Plan destination).
- *Ships value alone* and de-risks the sync wiring before the planner depends on it.

**Phase 2 (v1) — Cost calibration foundation** *(after Phase 1 ships; owner sign-off)*
- Additive `Recipe` fields: `baseline_cost_estimate` + health signal (populate
  `nutrition`).
- `regional_multiplier(location)` (LLM-estimated) + the pre-ship ordering sanity
  check; location capture on the client.

**Phase 3 (v1) — The planner** *(owner sign-off)*
- `POST /v1/plan`: budget + location + On-Hand snapshot + constraints →
  generation-first sourcing (C1), budget/On-Hand-aware generation prompt(s),
  per-recipe annotation, cost math, missing-ingredients list (with display
  snapshots).

**Phase 4 (v1) — iOS results + convergence** *(owner sign-off)*
- Plan-results UI; "just what's missing" via `GroceryAggregator` **minus On Hand**;
  commit accepted recipes into `meal_plan` so Meal Plan + Grocery List light up.

**Explicitly deferred to v2 (leave room, don't design now)**
- Auto-decrementing On Hand when a recipe is cooked; reconciling On Hand against
  Grocery List check-offs.
- **Cache-first sourcing** (the C1 search/index layer), gated on the recurrence
  signal above.
- Persisted plan **history** (`budget_plan` collection).
- Unit conversion in the missing-ingredients math.
- A dedicated server-side On Hand table / server-side reasoning without the client.
