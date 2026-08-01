# RecipeApp

Turn a shared Reel, TikTok, or recipe blog link into a real, structured recipe — automatically.

RecipeApp extracts ingredients, instructions, servings, and images from Instagram Reels, TikTok videos, and general recipe websites, then helps you plan meals for the week and build a grocery list from what you've planned.

---

## What it does

- **Save recipes from anywhere** — paste an Instagram Reel, TikTok link, or a recipe blog URL and get a structured recipe back: ingredients, step-by-step instructions, servings, and an image.
- **Meal Plan** — assign saved recipes to days across a 7-day week view, navigate between weeks.
- **Grocery List** — a shopping list generated automatically from whatever's planned for a given day or the whole week, grouped by aisle (Produce, Dairy, Pantry, etc.), with manual add-ons for anything not tied to a recipe.
- **Discover** *(coming soon)* — browse recipes shared by other users.

## How extraction works

RecipeApp uses a tiered strategy depending on the source, always preferring ground-truth data over AI guessing:

| Source | Strategy |
|---|---|
| Recipe blogs with structured data | Reads the page's embedded `schema.org` Recipe markup directly — no AI involved, highest confidence |
| Recipe blogs without structured data | Extracts the article's main text and runs it through an LLM extraction pipeline |
| Instagram Reels | Extracts the video caption, runs it through the same LLM extraction pipeline |
| TikTok | Same, via video metadata |

In every case, the extraction pipeline is instructed to **never invent ingredients or steps** it can't find in the source. If a source has ingredients but no described method, RecipeApp falls back to generating a reasonable method for that specific dish — and clearly labels it as such in the app, so you always know whether a recipe is verbatim from its source or AI-assisted.

Submissions are processed asynchronously: submitting a link returns instantly, and the recipe resolves in the background — including surviving the app being closed mid-extraction.

---

## Architecture

```
RecipeApp/
├── backend/              Python + FastAPI + SQLite
│   ├── app/
│   │   ├── main.py           API routes (POST /v1/jobs, GET /v1/jobs/{id})
│   │   ├── models.py         Pydantic models (Job, Recipe, Ingredient, ...)
│   │   ├── db.py             SQLite storage, WAL mode
│   │   └── pipeline/
│   │       ├── urls.py           URL resolution & platform detection
│   │       ├── fetch.py          Instagram / TikTok metadata fetching
│   │       ├── web.py            Safe web fetching for blog URLs
│   │       ├── netguard.py       SSRF protection for arbitrary URL fetches
│   │       ├── jsonld.py         schema.org Recipe parser
│   │       ├── signal.py         Recipe-content detection
│   │       ├── llm.py            LLM-based extraction (OpenAI)
│   │       ├── images.py         Thumbnail / stock photo resolution
│   │       └── orchestrator.py   Ties the pipeline together
│   └── tests/
└── ios/
    ├── RecipeApp/            Main SwiftUI app target
    │   ├── Views/                Tab views: Recipes, Meal Plan, Grocery List, Discover
    │   └── Providers/             App-side state coordinators
    ├── RecipeKit/             Shared Swift package (models, networking, local storage)
    │   ├── Models/
    │   ├── Networking/            API client, typed error handling
    │   └── Storage/               App Group–backed local persistence
    └── ShareExtension/        iOS Share Extension (share a link directly from Instagram/TikTok)
```

### Backend

- **FastAPI** serving a small async job API: submit a URL, poll for status, get back a structured recipe.
- **SQLite** with WAL mode, persisted on a Railway volume — chosen deliberately over Postgres for zero operational overhead at this scale.
- Recipes are **cached by canonical source** (video ID or normalized URL) — resubmitting the same link never re-extracts or re-spends an LLM call.
- Outbound fetches to arbitrary user-submitted URLs are protected against SSRF: private/loopback/link-local IP ranges are blocked before every fetch and every redirect hop.

### iOS app

- **SwiftUI**, targeting iOS 17+.
- **RecipeKit** is a local Swift package shared between the main app and the Share Extension — it owns the data models, the API client, and local persistence, so both targets stay in sync without duplicated logic.
- All local state (pending jobs, meal plan entries, grocery checklist state, saved recipes) is persisted via an **App Group–backed store**, so data survives app relaunches and is shared correctly between the app and the Share Extension.
- An anonymous per-device user identity is generated once and stored in the shared Keychain access group.

---

## Status

This is an actively developed personal project, not a finished product. Current state, roughly:

**Working:**
- Recipe extraction from Instagram, TikTok, and general recipe blogs
- Async job processing with background persistence
- Meal Plan (7-day view, recipe assignment)
- Grocery List (day/week toggle, category grouping, manual items)
- Local recipe/job persistence across app relaunches

**In progress / known gaps:**
- Share Extension is fully implemented but requires a paid Apple Developer account to test on a physical device (App Groups isn't available on free accounts)
- No backend authentication yet — protected only by a lightweight rate limit
- Discover tab is a placeholder — no accounts or public recipe visibility yet
- No support yet for adding a recipe via photo (OCR) or manual typing — blog/Instagram/TikTok import only, for now

---

## Running it locally

### Backend

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

You'll need an OpenAI API key set as an environment variable for the extraction pipeline to work.

### iOS app

Open `ios/RecipeApp.xcodeproj` in Xcode. Requires Xcode 16+ (uses synchronized folder groups) and iOS 17+ as a deployment target.

To build the Share Extension target, you'll need:
- A paid Apple Developer Program membership (required for the App Groups capability)
- The same App Group identifier configured on both the main app and extension targets

---

## Tech stack

**Backend:** Python, FastAPI, SQLite, OpenAI API, BeautifulSoup, trafilatura
**iOS:** Swift, SwiftUI, Swift Package Manager
**Infrastructure:** Railway (hosting + persistent volume)

---

## License

_Add a license here before making this repository public._
