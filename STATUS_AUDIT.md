# STATUS_AUDIT.md

Read-only full-context audit of the Recipe / Platter codebase.
Generated 2026-09-15 against `main` @ `9fc8813`. No code was changed.

Verification basis for this pass:
- Backend Python test suite: **74 tests, all passing** (`python -m unittest discover -s tests`, run 2026-09-15 in `.venv`, Python 3.9).
- iOS/RecipeKit: **could not be built or tested locally** — only Command Line Tools are installed (`xcode-select -p` → `/Library/Developer/CommandLineTools`), no full Xcode. All Swift findings are from source reading, not compilation.

---

## 1. Repo map

Top-level (`/Users/asmitbhardwaj/Documents/Recipe/RecipeApp`):

| Path | What it is | Tracked? |
|------|-----------|----------|
| `app/` | FastAPI backend (Python) | tracked |
| `tests/` | Backend `unittest` suite | tracked |
| `ios/RecipeApp/` | SwiftUI app target | tracked |
| `ios/RecipeKit/` | Swift package (models, networking, sync, storage, notifications) — the testable core | tracked |
| `ios/ShareExtension/` | Share Extension target | tracked |
| `ios/RecipeApp.xcodeproj/` | Xcode project | tracked |
| `docs/` | `SMOKE_TEST.md`, `budget-meal-planning.md` | **UNTRACKED** (whole dir is `??`) |
| `platter-landing/` | `platter-landing.html` (marketing page) | **UNTRACKED** |
| `onboarding/` | Source PNGs for onboarding art | **UNTRACKED** |
| `scripts/` | `migrate_sqlite_to_postgres.py` (tracked), `delete_smoke_accounts.sql` (untracked) | mixed |
| `probe/` | `probe.py`, `results.json`, `urls.txt` — extraction validation harness | tracked |
| `pictures/` | Raw ingredient source art — **gitignored** (`/pictures/`) | ignored |
| `.github/workflows/ci.yml` | CI | tracked |
| `CLAUDE.md` | Project source-of-truth spec | tracked |
| `README.md`, `railway.json`, `requirements.txt`, `.env.example` | infra/docs | tracked |
| `.env`, `recipes.db`, `ios/Secrets.xcconfig` | local secrets/state | **gitignored (safe)** |

`platter-landing` is present but is a **single static HTML file**, not a separate app/project.

**iOS layering:** app-level UI/view-models live in `ios/RecipeApp/`; all reusable, unit-tested logic (models, `APIRecipeProvider`, auth API, sync engine, stores, cook-timer scheduling) lives in `ios/RecipeKit/Sources/RecipeKit/` with tests in `ios/RecipeKit/Tests/RecipeKitTests/` (24 test files).

---

## 2. Backend (FastAPI)

### 2.1 DB layer (`app/db.py`) — SQLite or Postgres?

**Runtime-selected, defaults to SQLite.** `_database_url()` (`app/db.py:188`):
- If `config.DATABASE_URL` is set (Railway Postgres) → normalized to `postgresql+psycopg://` (`_normalize_url`, `db.py:178`) → **Postgres**.
- Otherwise → `sqlite:///{config.DB_PATH}`, default `recipes.db` (`config.py:18`, `config.py:24`).

Single SQLAlchemy Core layer over both; upserts use dialect-specific `insert().on_conflict_*` chosen in `_insert()` (`db.py:229`). Local dev/tests use SQLite with no Postgres required. The committed root `recipes.db` (110 KB) is a **local SQLite file** and is gitignored via `*.db` — it is not the production store.

Schema (all in `db.py`): `jobs`, `recipes` (UNIQUE `canonical_video_id` = cache/idempotency key, `db.py:62`), `user_recipes`, `rate_limits`, `feedback`, `users`, `auth_identities`, `refresh_tokens`, `sync_items`, `sync_state`. Recipes/jobs are stored as JSON blobs with lookup keys promoted to columns.

`scripts/migrate_sqlite_to_postgres.py` exists (tracked) for the one-time SQLite→Postgres move.

### 2.2 Pipeline structure

Entry: `POST /v1/jobs` (`app/main.py:143`) → `orchestrator.create_job` (persists `queued`) → `BackgroundTasks` runs `orchestrator.process_job`. **This is in-process `BackgroundTasks`, NOT a real job queue/worker** — acknowledged in code (`orchestrator.py:6`, "Background queue/workers are a later optimization"). `POST` returns the `job_id` immediately; client polls `GET /v1/jobs/{job_id}` (`main.py:164`).

`orchestrator.process_job` (`orchestrator.py:89`) flow:
1. `urls.resolve` → canonical id + platform (`urls.py:89`). Platforms: `tiktok`, `instagram`, or **`web`** (generic blog). Shortlinks (`vm/vt.tiktok.com`, `instagr.am`) expanded via redirect (`urls.py:72`).
2. **Cache check** by `canonical_video_id` (`orchestrator.py:109`) — returns cached recipe, no re-extraction (CLAUDE.md §7 satisfied).
3. Branch by platform:
   - **`web`** → `_process_web` (`orchestrator.py:274`): SSRF-guarded `web.safe_get` → JSON-LD (`jsonld.parse_recipe_jsonld`, `source_type="structured"`, no LLM) → else `trafilatura` article text → `llm.extract_recipe_from_article` (`source_type="article"`).
   - **`instagram`** → `fetch.fetch_instagram_metadata` (embed `/embed/captioned/` scrape, `fetch.py:174`).
   - **`tiktok`** (else) → `fetch.fetch_metadata` via **yt-dlp** (`fetch.py:52`).
4. Signal check (`signal.has_recipe_signal`, ≥2 of units/numbered-list/keywords, `signal.py:35`) → full `llm.extract_recipe`, else dish-ID → `llm.generate_generic_recipe` fallback.
5. **Gap fix (real ingredients, zero steps):** `orchestrator.py:142` — an ingredients-only caption gets a generated method for those exact ingredients and is flagged `source_type="generated"`. Same fix repeated in `_process_web` (`:309`) and `process_pasted_text` (`:240`).
6. Image resolution → assemble `Recipe` → `_finalize` (save recipe, save user-recipe join, mark complete, **clear stale `error_code`**, `orchestrator.py:64`).

**Paste fallback** `POST /v1/jobs/{job_id}/paste` (`main.py:176` → `orchestrator.process_pasted_text`, `:187`):
- Synchronous (caller is actively waiting). App-key gate + rate-limit as submit path. Rejects text < 10 chars (`main.py:196`).
- Retries the SAME job in place: reuses resolved `canonical_video_id` (synthesizes `paste:{url}` if none, `:214`), sets `extraction_method="pasted_text"`, routes caption-shaped (`instagram`/`tiktok`) → `extract_recipe`, else article-shaped → `extract_recipe_from_article`. Caches result under the canonical id so **one user's paste populates the shared cache for everyone** who later submits the URL.

**yt-dlp is run inline in `fetch.py`, NOT as an isolated microservice** — CLAUDE.md §5/§7 mandate isolating it in its own auto-updated service. Code comment (`fetch.py:4`) acknowledges this as future work. Flag below.

### 2.3 error_code routing (how it actually works)

`error_code` is a stable machine string set on the `Job` when `_fail` is called (`orchestrator.py:45`). Sources:
- `fetch.py:_classify` (`:39`) maps yt-dlp error text → `private_video` / `video_unavailable` / `login_required` / `unsupported_url` / `fetch_failed`.
- `fetch.py:209` (Instagram) → `caption_not_found`.
- `web.py` → `site_blocked` (bot-protection/paywall/challenge; statuses `{401,402,403,406,429,451,503}` at `web.py:41`, or challenge markers at `:46`), `fetch_failed`, `not_html`, `too_large`, `too_many_redirects`.
- `netguard` → `blocked_scheme`, `blocked_host`, `dns_error`.
- `orchestrator` → `invalid_url`, `could_not_identify_dish`, `no_recipe_found`.
- `llm` → `missing_api_key`, `llm_api_error`, `invalid_llm_output`, `llm_refusal`.

The **iOS side mirrors this** in `RecipeProviderError.swift`:
- `pasteEligibleCodes` (`:59`) = `site_blocked, fetch_failed, too_many_redirects, not_html, too_large, dns_error, caption_not_found` — these show the "Paste recipe text" remedy.
- `failedJobMessage` (`:78`) maps ~18 codes to human copy, falling back to the backend message.
- **Drift/gap:** `could_not_identify_dish` and `no_recipe_found` are handled for *copy* but are **not** in `pasteEligibleCodes`, so a no-signal Instagram/TikTok caption that can't be dish-identified is a dead end with no paste offer. `blocked_host`/`blocked_scheme`/`private_video`/`video_unavailable`/`login_required` likewise get copy but no paste path (mostly by design — pasting can't fix a private video, but a blocked *caption* arguably could).

### 2.4 Rate limiting / SSRF / caching / auth gating

- **Rate limiting** (`app/ratelimit.py`): persistent fixed-window counters in the DB (`rate_limits` table), two dimensions (user-id header + IP) × two windows (min/hour). Limits in `config.py:95-100` (user 8/min, 40/hr; IP 15/min, 100/hr). Increment-then-compare; probabilistic cleanup (`_CLEANUP_PROBABILITY=0.01`). Applied to `/v1/jobs`, `/v1/jobs/{id}/paste`, `/feedback`. **Not** applied to `GET` polling (intentional, `main.py:147`).
- **SSRF guard** (`app/pipeline/netguard.py`): `assert_fetchable` blocks non-http(s) schemes and any host resolving to private/loopback/link-local/reserved/multicast/unspecified IPs; unwraps IPv4-mapped IPv6; checks **every** resolved address; re-validated on every redirect hop (`web.safe_get`, redirects followed manually). **Known residual risk documented in-code** (`netguard.py:17`): TOCTOU / DNS-rebinding window because `requests` re-resolves on connect — mitigation (pin vetted IP) deferred.
- **Caching**: `canonical_video_id` UNIQUE + cache check before any extraction (`orchestrator.py:109`). Web URLs normalized (tracking params stripped, trailing slash dropped) so UTM variants collapse to one entry (`urls.py:46`).
- **App-key gate** (`main.py:52`): middleware checks `X-App-Key` (constant-time) on every path except `/`, `/health`, `/admin/*`. **Fail-open** if `APP_KEY` unset server-side (dev/tests). It is abuse deterrence, not auth (key ships in the IPA).
- **Real auth** (`app/auth/`): JWT access (30 min) + rotating single-use refresh (60 d), tracked server-side by `jti`. Endpoints: register/login (brute-force guarded, `router.py:75`), Apple, Google (server-side identity-token verification, audiences from `APPLE_CLIENT_IDS`/`GOOGLE_CLIENT_IDS`), refresh, logout, `GET/DELETE /auth/me`. `current_user` dependency (`router.py:93`) gates the sync API. `JWT_SECRET` has an insecure dev fallback with a startup warning (`main.py:35`).
- **Sync API** (`app/sync.py`): `POST /v1/sync/push`, `GET /v1/sync/pull`, `POST /v1/recipes/batch` — all `current_user`-gated. Last-writer-wins by client `updated_at`, per-user monotonic `seq` cursor, opaque per-collection payloads, allowlisted collections (`db.SYNC_COLLECTIONS`, `db.py:378`).

### 2.5 CLAUDE.md §4 enum drift (code vs spec) — **FLAGGED**

The code has diverged from the §4 data model. Most drift is intentional and documented in-code, but §4 itself was not updated:

| Field | CLAUDE.md §4 says | Code actually has | Where |
|-------|------------------|-------------------|-------|
| `Recipe.source_type` | `"caption \| generated"` | `"caption" \| "generated" \| "structured" \| "article"` | `models.py:100` |
| `Recipe.image_source` | `"video_thumbnail \| stock_photo \| none"` | adds `"web_image"` | `models.py:103` |
| `Job.platform` | `"instagram \| tiktok"` | adds `"web"` | `models.py:116` |
| `Job.extraction_method` | only `"caption_only"` (comment says future values "slot in") | code assigns `"pasted_text"` at runtime | `orchestrator.py:211` |
| `Job.error_code` / `Job.error` | not in §4 | present (documented as intentional add) | `models.py:124` |
| `Recipe.transcript` / `nutrition` | not in §4 | nullable future-proofing placeholders | `models.py:107` |

None break the app (all additive), but §4 is now stale documentation. The `image_source` badge story in §5 is honored for web (`web_image` → "From the site").

---

## 3. iOS app (SwiftUI / RecipeKit)

### 3.1 Identifiers, signing, App Group (read from actual files)

- **App Group:** `group.com.recipeapp.shared2` — consistent across `ios/RecipeApp/RecipeApp.entitlements` and `ios/ShareExtension/ShareExtension.entitlements`.
- **Bundle IDs** (`RecipeApp.xcodeproj/project.pbxproj`): app `com.recipeapp.RecipeApp2`, extension `com.recipeapp.RecipeApp2.ShareExtension`.
- **Signing team:** `DEVELOPMENT_TEAM = 3X4GVUTA76` (all four build configs).
- **Sign in with Apple** entitlement present (`com.apple.developer.applesignin` = `Default`) on the app target.
- **Secrets** (`ios/Secrets.xcconfig`, gitignored, present locally): real `APP_KEY`, real `GOOGLE_CLIENT_ID` + reversed id are populated. `Secrets.example.xcconfig` (committed) documents the wiring: value flows xcconfig → `RecipeApp-Info.plist` (`APP_KEY = $(APP_KEY)`) → `AppConfig.infoString` at runtime (`AppConfig.swift:50`, guards against unexpanded `$(` placeholder). **Google Sign-In is fully wired** (client id present); `AppConfig.isGoogleConfigured` gates the UI.
- **API base URL** (`APIRecipeProvider.swift:26`): `https://recipeapp-production-3a60.up.railway.app`.

### 3.2 Share Extension

`ShareViewController.swift` does exactly the spec's submit-and-close: presents `ShareRootView` immediately (doesn't block on `loadItem`), extracts a URL (URL provider → plain-text-with-URL fallback via `NSDataDetector`), completes the request when the SwiftUI view finishes. Real submission/persistence is delegated to `ShareRootView`/RecipeKit. `NSExtensionActivationRule` is `TRUEPREDICATE` (accepts everything — broad, but the view degrades to an "unsupported link" state).

### 3.3 Auth flow

Implemented: `AuthModel`, `GoogleSignInController`, `SignInView`, `AuthAPI` (RecipeKit, URLProtocol-testable), `AuthSessionStore` (Keychain), `SyncCoordinator`. Apple + Google + email/password all present client-side. `AuthTests`, `IdentityLogicTests`, `LegacyDataClaimerTests` exist.

### 3.4 Cook Mode

Present and substantially built (matches the memory's "Stage 1 slices 1–6 shipped"): `CookModeView`, `CookModeModel`, `CookClock`, `CookStepTimerCard`, `ActiveTimersBadge`, `CookTimerSchedulerEnvironment`, plus RecipeKit `CookTimerStore`, `CookTimer`, `StepDurationParser`, and `CookTimerNotification*` scheduling (with a `UN`-backed impl). Tests: `CookTimerStoreTests`, `CookTimerNotificationTests`, `StepDurationParserTests`, `MinutesStringTests`. `ActiveTimersBadge.swift:12` notes multi-timer list is deferred (single jump target for now). Per-step `duration_seconds` is populated by the backend (`models.py:43`) with client regex fallback.

### 3.5 Paste-recipe-text UI

`PasteRecipeTextView.swift` (overlaid placeholder since `TextEditor` has none, `:47`) + `RecipeProviderError` (`pasteEligibleCodes`, `canPasteText`, `failedJobMessage`) + `APIRecipeProvider.submitPastedText` (`:108`). `FailureAlertView` surfaces the failed-job state app-wide. Wiring looks complete; not runtime-verified (no simulator).

### 3.6 In-progress / half-built / out-of-docs

- **`DiscoverView.swift` is dead code** — explicitly a placeholder (`:5`), **not in the tab bar** (`MainTabView.swift:7` says "still exists but intentionally not in the tab bar"). README lists Discover as "coming soon." Kept for later.
- **`GeneratedBadge`** (`Badges.swift:15`) is built but **intentionally never rendered** (`RecipeListView.swift:152`), per CLAUDE.md §5's "no generated badge" decision. Kept so the distinction can be reinstated.
- **Stale comment:** `MainTabView.swift:7` says "Grocery List is a 'coming soon' shell for now" — but Grocery List is a **fully wired `GroceryListView`** (`:73`) with categories, manual items, day/week toggle (README + smoke test §5 treat it as real). The comment is outdated.
- Onboarding art (`ios/RecipeApp/Views/Onboarding/*`) is mid-change — both onboarding Swift files are modified-unstaged and all onboarding imagesets are newly-added-staged (see §6).

### 3.7 Scope drift vs CLAUDE.md §2 — **FLAGGED**

CLAUDE.md §2 specifies a **"Simple two-tab app: Recipes and Account,"** and lists Meal Planner, Grocery Lists, Folders/Collections (cookbooks), and Cook Mode as **explicitly out of MVP scope / "later."** Reality on `main`:
- **Three tabs** (Recipes, Meal Plan, Grocery List; `MainTabView.swift:36`); Account is a toolbar entry, not a tab.
- **Meal Plan, Grocery List, Cookbooks (folders), Cook Mode, cross-device Sync, and real Auth are all built and shipped.**

This is a large, deliberate expansion well beyond the documented MVP. It is real, tested code — but CLAUDE.md §2 no longer describes the app. Anyone taking §2 as current will be wrong.

---

## 4. CI (`.github/workflows/ci.yml`)

Runs on every push and PR, `macos-latest`, two jobs:
1. **`recipekit-tests`** — selects full Xcode, runs `swift test` in `ios/RecipeKit`.
2. **`app-build`** — copies `Secrets.example.xcconfig` → `Secrets.xcconfig` (placeholder), then `xcodebuild build` of the `RecipeApp` scheme for the iOS Simulator with `CODE_SIGNING_ALLOWED=NO`.

It does **not** run the Python backend suite (that's local-only right now). **Whether CI is green on `main` could not be confirmed from this machine** (no Xcode, no `gh`/network check performed). The backend suite passes locally (74/74). The last commits touching CI (`b702e7e`, `6a774ae`) predate the recent backend/onboarding work, and no CI-related failures are visible in the tree, but treat "CI green on main" as **unverified**.

---

## 5. Docs vs. reality

- **`CLAUDE.md`** — read in full. Source-of-truth spec. Drift flagged in §2.5 and §3.7 above: §2 (two-tab/MVP scope) and §4 (source_type/image_source/platform/extraction_method enums) are both stale relative to code.
- **`docs/budget-meal-planning.md`** — read in full. A forward-looking *planning* doc (status: "Planning," decisions locked 2026-09-04). Not yet implemented — explicitly says "Do not write feature code until the §6.1 blocker is cleared" and that as of 2026-09-04 the blocker is **not fully clear**. Introduces the `docs/` folder. Notes the **dangling `TODO.md` reference** (below).
- **`docs/SMOKE_TEST.md`** — read in full. Manual pre-launch QA checklist. **The entire `docs/` dir is untracked**, so this checklist and its results are not committed.

  SMOKE_TEST checklist state (as written):
  - **Done `[x]`:** §3 backend items only — `GET /` + `/health` (dialect postgresql), good-blog extraction (Love & Lemons), blocked-site `site_blocked` (AllRecipes), paste fallback clears error_code. All annotated "verified 2026-09-15."
  - **Open `[ ]`:** everything else — all §1/§2/§4/§5/§6/§7/§8/§9/§10 items (onboarding, Share Extension, paste UI, meal plan/grocery, cook mode, auth, sync, feedback, store readiness). Deferred because no Xcode/device on the audit machine.
  - **Stale/inconsistent:** line 43 (app-key gate rejects bad `X-App-Key`) is checkbox `[ ]` **unchecked** yet annotated "verified 2026-09-15 (incidental)" — the checkbox and the note disagree. Line 44 (idempotency/cache) is unchecked with no note despite the cache being a hard, testable backend behavior.
  - Otherwise the checklist is **structurally current** — it references the real App Group id, the real paste endpoint, cook mode, sync, and Stage-4 claim, so it tracks the actual (post-MVP) app, not a stale one.

- **`TODO.md` — dangling reference.** `fetch.py:88` and `fetch.py:216` point readers to `TODO.md` (re: Instagram thumbnails deliberately skipped), but **no `TODO.md` exists** in the repo. The budget doc (`docs/budget-meal-planning.md`) calls this out and suggests creating it or repointing the comments.

---

## 6. Git state

- **Branch:** `main`. **Ahead/behind origin/main: 0 / 0** (level with remote).
- **Staged (`A`/`M` in index):** the new AppIcon (`platter_app_icon_1024.png` + `AppIcon.appiconset/Contents.json`) and six onboarding imagesets (`onboarding-cookbook/grocery/paste-link/planweek/share/welcome`, each `Contents.json` + PNG).
- **Unstaged (`M` worktree):** `ios/RecipeApp/Views/Onboarding/OnboardingIllustrations.swift`, `OnboardingView.swift`.
- **Untracked (`??`):** `docs/`, `onboarding/`, `platter-landing/`, `ios/RecipeApp/Assets.xcassets/MILP_Solver_Evaluation.pptx` (a stray PowerPoint mis-filed inside the asset catalog — almost certainly should not be there), `scripts/delete_smoke_accounts.sql`.
- **Working tree is mid-change** (onboarding art swap in progress; docs not yet committed). Nothing is lost, but a commit is pending.

Last 15 commits:
```
9fc8813 Clear stale error_code when a job finalizes to complete
6ce926e Add manual paste-recipe-text fallback for blocked/unreadable sources
995873c Degrade gracefully when a site blocks our fetch
9eaf27e Add /health readiness route with a real DB check
dd854c3 Remove generated-recipe explanatory note; update CLAUDE.md §5
70d8508 Stop rendering the Generated-recipe badge in the UI
e0aa389 Merge pull request #4 from AsmitBhardwaj/cook-mode-stage-1
13387e6 Tighten Generated-recipe badge spacing on recipe cards
b2f5e31 Merge pull request #3 from AsmitBhardwaj/ci-swift-xcodebuild
b702e7e CI: bump actions/checkout v4 -> v5
6a774ae CI: swift test for RecipeKit + xcodebuild of the app on push/PR
0422b40 Merge pull request #2 from AsmitBhardwaj/cook-mode-stage-1
e9de685 Grocery List: drop the dashed torn-edge border on cards
03a90f9 Cook Mode Stage 1 (slice 6): Cook Mode UI
591456f Cook Mode Stage 1 (slice 5): step-timer notifications
```

---

## 7. Open threads

### TODO/FIXME/dead code
- **No literal `TODO`/`FIXME`/`XXX` in Python or Swift source** except the dangling `TODO.md` references (`fetch.py:88`, `:216`). "placeholder"/"stub" hits are all descriptive comments or UI placeholders, not open work.
- **Dead/parked code paths:** `DiscoverView` (built, not in tab bar), `GeneratedBadge` (built, never rendered), `Job.transcript`/`nutrition` + `extraction_method` future-value plumbing (nullable placeholders by design).
- **Instagram thumbnails always `None`** (`fetch.py:216`) — IG recipes never use `video_thumbnail`; they always fall through to stock photo or none. Intentional, but means the "From video" badge effectively never appears for Instagram.

### Notable gaps between spec and implementation
- **Push notifications have no backend** — `grep` for APNs/`content-available`/device tokens across `app/` returns **nothing**. CLAUDE.md §6 describes silent + visible push as reconciliation layers 1 & 2; only **layer 3 (foreground reconcile)** exists (`MainTabView.swift:80-88`). The app is correct (layer 3 is the safety net) but is running on the safety net alone.
- **yt-dlp is inline, not an isolated microservice** (CLAUDE.md §5/§7) — `fetch.py` imports and runs `yt_dlp` in-process in the API server.
- **Job pipeline is synchronous `BackgroundTasks`, not a queue/worker** (CLAUDE.md §3) — fine for beta scale, but a slow scrape/LLM call ties up a server worker.
- **Apple token revocation on account deletion appears NOT implemented.** `DELETE /auth/me` (`router.py:207`) calls only `db.delete_account`. `config.py:61` declares `APPLE_TEAM_ID`/`APPLE_KEY_ID`/`APPLE_PRIVATE_KEY` "unused until Stage 5," and no revoke-with-Apple call exists in `app/auth/`. Apple requires calling their revocation endpoint on account deletion (App Store review). Auto-memory records Stage 5 as "done & verified" — **this contradicts that**; verify before relying on deletion being App-Store-complete.

---

## Top open items (ranked by what's actually blocking)

1. **Confirm CI is green on `main`.** Could not be checked here (no Xcode/network). Everything downstream assumes a buildable app + passing `swift test`. Verify first. *(blocking — unknown state)*
2. **Apple Sign-In token revocation on account deletion is missing.** Likely an App Store review blocker for 5.1.1 despite memory marking Stage 5 done. Verify/implement in `DELETE /auth/me`. *(blocking for store submission)*
3. **Commit the working tree** — `docs/`, onboarding art (staged + unstaged Swift), `scripts/delete_smoke_accounts.sql`, `platter-landing/` are all uncommitted; SMOKE_TEST results live only in an untracked file. The repo's documented QA state isn't in git. Also remove the stray `MILP_Solver_Evaluation.pptx` from the asset catalog. *(blocking clean handoff)*
4. **Reconcile CLAUDE.md with reality** — §2 (two-tab MVP) and §4 (source_type/image_source/platform/extraction_method enums) are stale; the app now ships Meal Plan, Grocery, Cookbooks, Cook Mode, Sync, Auth. Anyone trusting §2/§4 as current will be misled. *(blocking correct follow-up scoping)*
5. **Push-notification backend** (§6 layers 1–2) is entirely absent; app relies solely on foreground reconcile. Decide whether that's acceptable for launch. *(not blocking core loop; degrades freshness)*
6. **Lower-priority cleanups:** create/ repoint `TODO.md` (dangling from `fetch.py`); fix stale "Grocery coming soon" comment in `MainTabView.swift:7`; consider adding `caption_not_found`-adjacent codes (`could_not_identify_dish`) to paste-eligible; move yt-dlp to its own service and the pipeline to a real queue when scale warrants. *(non-blocking)*
