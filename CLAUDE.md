# CLAUDE.md — Recipe Extraction App

This file gives Claude Code full context on the project. Read this before making
architectural decisions, generating code, or suggesting new features. When a
request conflicts with the MVP scope below, flag it rather than silently
expanding scope.

---

## 1. What this app does

Users share an Instagram Reel or TikTok link via the iOS Share Sheet. The app
extracts the recipe from the video's caption, cleans it up with an LLM, and
shows it as a structured recipe (title, ingredients, steps) in the user's
personal recipe list.

**Core loop:** share a link → see a clean recipe. That loop must always work
reliably and stay fast. Every other feature is secondary to protecting this
loop.

---

## 2. MVP scope — build this first, nothing more

### In scope for MVP
- iOS Share Extension that captures a shared URL and hands it to the backend
- Backend job pipeline: URL → caption/metadata fetch → LLM extraction →
  structured recipe
- Caching by canonical video ID (never re-extract or re-call the LLM for a
  video already processed — return the cached recipe instead)
- Fallback path when the caption has no usable recipe content: identify the
  dish by name, then generate a clearly-labeled generic recipe for it
- Recipe image: use the video's thumbnail if it looks food-relevant; otherwise
  fall back to a stock photo (Unsplash or Pexels API) matched by recipe title;
  otherwise no image
- Simple two-tab app: **Recipes** (list + detail) and **Account**
- Free and unlimited: extraction has no usage cap and no paywall

### Explicitly OUT of scope for MVP — do not build unless asked
- Audio transcription (Whisper) — deferred to a future paid tier
- OCR of on-screen text or video frames — deferred
- AI-generated images (e.g. Nano Banana) — deferred; MVP uses only real
  thumbnails and stock photos, never a generated image
- Nutrition / calorie / macro breakdown — paid tier, later
- Folders, collections, custom drag-and-drop ordering — paid tier, later
- Suggested recipes from other users' vaults — later, needs real usage data
  first
- Meal planner / calendar — later
- Grocery lists with realtime sync — later
- Cooking mode for multiple recipes at once — later
- AI recipe generation from scratch ("surprise me", "by ingredients") — later,
  cheap to add later since it reuses the same extraction schema and validation
- Cookbook / handwritten recipe photo capture (OCR pipeline) — later, hardest
  feature, treat as its own project when it comes up

If a request implies building something in this "out of scope" list, say so
explicitly before proceeding, and confirm whether the user actually wants to
expand MVP scope right now.

---

## 3. Architecture overview

```
[User taps Share in IG/TikTok]
        │
        ▼  CLIENT (iOS)
[Share Extension: grab URL, POST to backend, get job_id, close in <2s]
        │
        ▼  BACKEND
[Job queue picks up job]
        │
        ▼
[Resolve URL → canonical video ID (idempotency key)]
        │
        ▼
[Cache check: video ID already processed?] ──Yes──► [Return cached recipe]
        │ No
        ▼
[Fetch caption + metadata + thumbnail via yt-dlp]
        │
        ▼
[Caption has enough signal?] ──No──► [Dish-ID prompt → generic recipe,
        │ Yes                          clearly labeled as generated]
        ▼
[LLM extraction: caption → structured recipe JSON]
        │
        ▼
[Validate JSON against schema; retry once on malformed output]
        │
        ▼
[Resolve image: thumbnail → else stock photo search → else none]
        │
        ▼
[Save recipe, mark job complete]
        │
        ▼
[Push notification (silent + visible) wakes the app]
        │
        ▼  CLIENT (iOS)
[App fetches recipe, processing card morphs into finished recipe]
```

**Client responsibilities:** capture the share, show processing state, render
final recipes, local caching/offline list.

**Backend responsibilities:** everything expensive or slow — scraping,
LLM calls, validation, image resolution, push delivery.

**Hard rule:** the Share Extension must never wait on a slow operation. Its
only job is submit-and-close. All real work happens server-side.

---

## 4. Data model

### Job
```json
{
  "job_id": "uuid",
  "user_id": "uuid",
  "url": "string",
  "canonical_video_id": "string",
  "platform": "instagram | tiktok",
  "status": "queued | processing | complete | failed",
  "extraction_method": "caption_only",
  "created_at": "timestamp"
}
```
Keep `extraction_method` as an explicit field even though only `caption_only`
exists now — this is intentional so future values (`caption+transcript`, etc.)
slot in without a schema migration.

### Recipe
```json
{
  "recipe_id": "uuid",
  "canonical_video_id": "string",
  "title": "string",
  "servings": { "amount": "number | null", "unit": "string | null" },
  "prep_time_minutes": "number | null",
  "cook_time_minutes": "number | null",
  "total_time_minutes": "number | null",
  "ingredients": [
    {
      "quantity": "number | null",
      "unit": "string | null",
      "name": "string",
      "notes": "string | null"
    }
  ],
  "instructions": [
    { "step_number": "number", "text": "string" }
  ],
  "confidence": {
    "overall": "number (0-1)",
    "ingredients_complete": "boolean",
    "instructions_complete": "boolean",
    "missing_fields": ["string"]
  },
  "source_type": "caption | generated",
  "image_url": "string | null",
  "image_source": "video_thumbnail | stock_photo | none"
}
```

### User-recipe join (per-user personalization, kept separate from the
shared/cached recipe data)
```json
{
  "user_id": "uuid",
  "recipe_id": "uuid",
  "custom_name": "string | null",
  "sort_key": "string",
  "saved_at": "timestamp"
}
```
The underlying extracted recipe is shared/cached across all users who saved
that video. Custom naming, ordering, and folder membership are per-user and
live in this join table, not on the recipe itself.

---

## 5. Extraction pipeline details

### URL handling
- Normalize and expand shortlinks (`vm.tiktok.com`, etc.) before processing
- Extract the platform's canonical video/shortcode ID immediately — this is
  the idempotency key for caching

### Caption/metadata fetch
- Primary tool: **yt-dlp**, run as its own isolated microservice (not inline
  in the API server), since it needs independent, frequent updates as
  platforms change their internals
- Secondary fallback: oEmbed endpoints
- Do not build headless-browser scraping for MVP — only add if yt-dlp/oEmbed
  prove insufficient in practice

### Deciding if caption has enough signal
```
if caption contains ≥2 of: measurement units (cup, tbsp, oz, g),
   a numbered list pattern, ingredient-list keywords →
    proceed to full LLM extraction
else →
    go straight to dish-ID + generic recipe fallback
```

### LLM extraction system prompt
Use this prompt verbatim as the starting point:

```
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
   rambles or is out of order — infer logical cooking order from context.
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
CAPTION: <text>
```

### Dish-ID + generic recipe fallback (Tier 4)
Two-step, only triggered when caption lacks recipe signal:

**Step 1 — identify the dish:**
```
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
even a general dish, set dish_name to null.
```
If `dish_name` is null, do not generate a recipe — surface a "couldn't read
this one" state and offer manual entry.

**Step 2 — generate a generic recipe for the identified dish:**
```
Generate a standard, reliable recipe for the dish named below, incorporating
any distinguishing details provided. This is NOT based on a specific source —
generate from general culinary knowledge. Keep it approachable and correct,
not overly creative. Set "source_type": "generated" and set
"confidence.overall" to reflect that this is a generic reference recipe, not
an extracted one.
```

**UI requirement:** any `source_type: "generated"` recipe must be visually
distinguishable from an extracted one (badge, distinct accent) — never let a
generated recipe look identical to an extracted one. This is a hard rule, not
a nice-to-have; users must always be able to tell the difference.

### Validation
- Run all LLM output through strict schema validation (e.g. Pydantic)
  immediately. Malformed JSON gets exactly one retry with a corrective
  message, then fails the job cleanly.
- Confidence-based UI treatment:
  - `overall ≥ 0.75` → deliver as a normal, ready recipe
  - `0.4 ≤ overall < 0.75` → deliver but flag missing fields in the UI
  - `overall < 0.4` → do not auto-populate; show a "couldn't extract this"
    state with manual-entry option

### Image resolution
```
if video_thumbnail exists and looks food-relevant:
    recipe.image_url = video_thumbnail_url
    recipe.image_source = "video_thumbnail"
else:
    result = search_unsplash_or_pexels(recipe.title)
    if result:
        recipe.image_url = result.image_url
        recipe.image_source = "stock_photo"
    else:
        recipe.image_url = null
        recipe.image_source = "none"
```
- Do not call any AI image generation model in MVP. That is deferred.
- Always show a small, persistent badge on the recipe detail screen
  indicating `image_source` ("From video" vs "Stock photo") so users are
  never misled into thinking a stock photo is the creator's actual dish.

---

## 6. iOS client notes

- Share Extension (`ShareViewController`) does only this: extract the shared
  URL from `NSExtensionItem`, POST it to the backend with a short timeout
  (~5s), persist the returned `job_id` (or the raw URL on failure) to the
  shared App Group container, then call
  `extensionContext?.completeRequest(...)` immediately. No polling, no long
  waits, no heavy logic inside the extension.
- Main app reconciles pending jobs via three layers, in order of reliability:
  1. Silent push (`content-available: 1`) on job completion — best effort
  2. Visible push as a backup signal and re-engagement hook
  3. Foreground check of the App Group's pending-jobs list on every app open
     — this is the correctness safety net, since push can be throttled
- Show a processing/skeleton card the moment a share happens, driven by local
  App Group state — never leave the user without acknowledgment that a share
  was received.

---

## 7. Cost and reliability guardrails

- **Idempotency by canonical video ID is mandatory**, not optional — this is
  what prevents a viral video from triggering thousands of redundant LLM
  calls and scraping requests. Every job must check the cache before doing
  any extraction work.
- Use a small/cheap LLM tier for extraction — this task (reformat caption
  into JSON) does not need a large frontier model.
- Rate-limit per user to prevent abuse of the free, unlimited extraction
  tier (generous limit — should never affect a real user, only scripted
  abuse).
- Track cost-per-extraction and cache-hit rate from day one so real usage
  data informs decisions instead of guesses.
- yt-dlp is a fragile dependency (platforms change without notice) — keep it
  isolated in its own service, auto-updated, with basic success-rate
  monitoring so silent extraction-quality decline gets caught early.

---

## 8. Engineering conventions

- Prefer surgical, minimal diffs over rewrites when editing existing code.
  Discuss approach before writing code for anything non-trivial.
- Keep the extraction/validation/image-resolution stages as separate,
  independently testable functions or services — not one monolithic
  handler — since each will evolve independently (e.g. transcription gets
  added to the extraction stage later without touching image resolution).
- Nullable/unused fields for future features (e.g. `transcript`,
  `nutrition`) should be added to schemas proactively where cheap to do so,
  to avoid future migrations — but do not build the features themselves
  until asked.
- Any new feature request should be checked against Section 2 before
  implementation. If it's in the "out of scope" list, confirm with the user
  before building it.
