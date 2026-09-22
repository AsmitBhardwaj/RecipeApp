# KITCHEN_SCOPE.md

Scoping/estimation for a **"Kitchen"** feature — a persistent, per-user, cross-device
pantry (ingredients on hand), add/remove only for v1 (no quantities, no expiry).

Discovery only. No code was written. All findings are from reading the current
`main` (`9fc8813`). Verdict up front:

> **This is a half-day-to-one-day job, not a multi-day one.** The three existing
> features (Meal Plan, Grocery List, Cookbooks) are **NOT** each hand-rolled —
> they ride a single, genuinely generic sync mechanism. Kitchen slots into it as
> a new collection with almost no new sync code. The only real work is a small
> local store + model + a SwiftUI screen + tab wiring, plus registering the new
> collection in ~4 well-defined places. **The pantry-as-string-list shape is a
> good fit — better than the existing collections, not worse.**

---

## 1. How Meal Plan / Grocery List / Cookbooks sync today

### 1a. Backend — one generic mechanism, not per-feature

There is **no per-feature backend code at all.** Everything goes through one
generic collection store:

- **Storage:** a single table `sync_items` (`app/db.py:149`), keyed by
  `(user_id, collection, item_id)`, holding `seq` (server-assigned monotonic
  version), `updated_at` (client wall-clock ms, the LWW key), `deleted`
  (tombstone), and `payload` (**opaque JSON the server never interprets**). A
  companion `sync_state` table (`db.py:164`) holds the per-user `seq` counter.
  All sync CRUD is generic: `sync_push` (`db.py:402`), `sync_pull` (`db.py:470`),
  `_allocate_seq` (`db.py:383`).
- **Endpoints** (`app/sync.py`), all `current_user`-gated (Bearer token) and
  behind the app-key middleware:
  - `POST /v1/sync/push` — batch of `{collection, item_id, updated_at, deleted, payload}`; returns `{applied, conflicts, cursor}` (last-writer-wins; server-wins rows come back as `conflicts`).
  - `GET /v1/sync/pull?cursor=&limit=` — returns `{changes, cursor, has_more}` (everything since cursor).
  - `POST /v1/recipes/batch` — recipe-body hydration (library-specific; irrelevant to Kitchen).
- **The only place a collection name is enumerated backend-side** is the
  allowlist `SYNC_COLLECTIONS` (`db.py:378`):
  ```python
  SYNC_COLLECTIONS = frozenset({"library","meal_plan","grocery_check",
                                "grocery_manual","cookbook","cookbook_membership"})
  ```
  It's re-validated by the request model's field validator (`sync.py:44-49`). A
  collection not in this set is rejected with `unknown collection`.

**Backend cost to add a collection = add one string to that frozenset.** No new
route, no new table, no new request/response shape, no migration (the recipe/job
data and `sync_items.payload` are schemaless JSON blobs).

### 1b. iOS — a shared engine + a thin per-feature layer

The client is a mirror-plus-outbox model built on reusable RecipeKit pieces.
None of it is copy-pasted per feature:

- **`SyncEngine`** (`Sync/SyncEngine.swift`) — transport- and store-agnostic.
  `record/push/pull/sync`. It knows nothing about any specific collection; it
  hands each remote change to an injected `apply` closure.
- **`SyncClient`** (`Sync/SyncClient.swift`) — the HTTP layer for push/pull/batch.
  Fully generic.
- **`SyncChange` + `SyncCollection`** (`Sync/SyncModels.swift`) — `SyncCollection`
  is a `String` enum (`SyncModels.swift:16`) whose cases ARE the collections;
  `SyncChange` carries `collection/itemId/updatedAt/deleted/payload/seq`.
- **`SyncOutbox` / `SyncCursorStore`** (`Sync/SyncStores.swift`) and
  **`SyncMetadataStore`** (`Sync/SyncMetadataStore.swift`) — generic queue,
  cursor, and the side map of `collection|itemId → updatedAt` used for
  apply-side LWW. **These already work for any collection with zero changes** —
  `updatedAt` is a side map, so models don't even need an `updatedAt` field.
- **`SyncCodec`** (`Sync/SyncPayloads.swift:55`) — shared JSON encode/decode for
  payloads. Per-collection payload structs (e.g. `GroceryCheckPayload`,
  `MembershipPayload`, `LibraryPayload`) live here, but a model that's already
  `Codable` round-trips directly with no bespoke payload struct.
- **`SyncCoordinator`** (`RecipeApp/Auth/SyncCoordinator.swift`) — app-side hub.
  View models call `sync.record(collection, itemId:, payload:, deleted:)`
  (`SyncCoordinator.swift:58`); it stamps the clock, enqueues, debounced-pushes.

**The only genuinely per-feature code** is:
1. **The local store** — a small `UserDefaults`-backed struct (e.g.
   `CookbookStore.swift`, 69 lines; `GroceryCheckStore.swift`, 86 lines), scoped
   by user id via `scopedStorageKey(base, userScope)` (`Storage/StorageScope.swift`).
2. **A `case` in `LocalSyncApplier.apply`** (`Sync/LocalSyncApplier.swift:53`) —
   a `switch` over `SyncCollection` that decodes the payload into the right store.
   ~3–5 lines per collection (see `applyGroceryManual`, `:72`).
3. **The observable view model** — e.g. `CookbooksModel.swift` (112 lines),
   `GroceryListModel.swift` (79 lines) — wraps the store and calls `sync?.record`
   after each local mutation.
4. **The SwiftUI view** — e.g. `GroceryListView.swift` (756 lines, but that's a
   rich screen), `CookbooksGridView.swift` (241 lines).

Two more places enumerate collections for lifecycle correctness:
- **`AccountDataEraser.scopedBaseKeys`** (`Sync/AccountDataEraser.swift:19`) —
  the store's base key must be listed so account deletion wipes it.
- **`LegacyDataClaimer`** (`Sync/LegacyDataClaimer.swift`) — the Stage-4
  "claim pre-account data" migration. Kitchen is a brand-new feature with no
  pre-account data, so **it does NOT need a claimer branch** (see §3).

**Conclusion for §1:** genuinely generic. Adding Meal Plan → Grocery → Cookbooks
did not multiply the sync code; each added a store + a `switch` case + a VM + a
view. Kitchen is the same, and simpler than any of them.

---

## 2. Scope estimate for "Kitchen" (reusable pattern confirmed)

Kitchen v1 = a set of ingredient names on hand, add/remove, synced. The closest
existing analog is **`grocery_manual`** (a keyed list of user-typed item names) —
Kitchen is essentially that minus the period-scoping, so it's *simpler*.

Minimal diff, by layer:

- **Backend (~5 min):** add `"kitchen"` to `SYNC_COLLECTIONS` (`db.py:378`). One
  line. Optionally extend `tests/test_sync.py` to cover it. No route, table, or
  migration.
- **RecipeKit (~2–3 hrs):**
  - Add `case kitchen` to `SyncCollection` (`SyncModels.swift:16`).
  - New `PantryItem` model — `{ id, name, addedAt }`, `Codable` (mirror
    `GroceryManualItem.swift`, ~30 lines). Round-trips via `SyncCodec` directly;
    no bespoke payload struct needed.
  - New `PantryStore` — `UserDefaults`-backed `[PantryItem]` under base key
    `pantry_items_v1`, scoped via `scopedStorageKey` (mirror `CookbookStore`,
    ~60 lines: `all() / upsert / remove`).
  - Add a `case .kitchen:` to `LocalSyncApplier.apply` (`LocalSyncApplier.swift:53`)
    + a `PantryStore` property in both inits (`:29`, `:39`) and one
    `applyKitchen(_:)` helper (~4 lines, copy `applyGroceryManual`).
  - Add `"pantry_items_v1"` to `AccountDataEraser.scopedBaseKeys`
    (`AccountDataEraser.swift:19`).
- **App layer (~2–4 hrs):**
  - New `KitchenModel: ObservableObject` (mirror `GroceryListModel`, ~70 lines):
    `add(name:)` / `remove(_:)` → write store, then `sync?.record(.kitchen, ...)`.
  - New `KitchenView` SwiftUI screen (a simple add-field + list-with-swipe-delete;
    realistically ~120–200 lines — far below the 756-line GroceryListView, which
    is rich; closer to a trimmed CookbooksGridView).
  - Wire a 4th tab in `MainTabView.swift`: add `case kitchen` to the `Tab` enum
    (`:36`) and a `NavigationStack { KitchenView(...) }` `.tabItem` block (`:55`).
    Construct `KitchenModel` in `init` alongside the other models (`:39`).
- **Tests (~1 hr):** a `PantryStoreTests` (mirror `CookbookStoreTests`) and a
  round-trip case in `SyncStoreCodecTests`.

**Rough effort: ~0.5–1 day** for one engineer familiar with the codebase (call it
**4–8 focused hours**), including tests. The uncertainty is almost entirely in
the *UI polish* of `KitchenView`, not the plumbing — the sync path is a solved,
reused problem here. A bare-bones but shippable version (plain list, no design
love) is comfortably a **half day**.

No fourth-bespoke-implementation scenario applies — the generic pattern is real.

---

## 3. Pantry-specific risks / nonstandard fits

- **String-list fit is GOOD, not awkward.** The sync layer is deliberately
  built around opaque per-item JSON payloads and per-item ids, *not* around rich
  objects. The one rich-object case (`library`) is the exception that carries
  extra machinery (recipe-body hydration via `/v1/recipes/batch`,
  `pendingRecipeHydration` in `LocalSyncApplier`). Kitchen is the *simple* case —
  like `grocery_manual`/`grocery_check` — and needs none of that hydration path.
  A pantry of ingredient names is arguably the cleanest possible fit for this
  system.
- **Choose a stable `item_id` = the LWW unit.** Sync converges per `item_id`
  under last-writer-wins. Two sensible choices:
  - Random UUID per entry (like `GroceryManualItem.id`) — simplest; "add milk"
    twice creates two rows. Fine for add/remove v1.
  - Normalized name as the id (e.g. `name.lowercased()`) — gives natural
    dedupe ("milk" is idempotent) and makes remove-by-name trivial, at the cost
    that re-adding a just-removed name reuses the id (correct under LWW as long
    as `updatedAt` advances — `syncNowMillis()` guarantees that).
  Recommend **normalized-name id** for a pantry (dedupe is desirable here), but
  it's a one-line decision, not a risk.
- **Delete is a tombstone, and that's already handled.** `sync?.record(...,
  deleted: true)` + the applier's remove path is the established pattern
  (`CookbooksModel.delete`, `applyGroceryManual`). Nothing new.
- **`updated_at` is client wall-clock ms** (`syncNowMillis`). A device with a
  badly wrong clock could lose a race — but this is an existing, accepted
  property of all four collections, not something Kitchen introduces.
- **No Stage-4 legacy-claim needed.** `LegacyDataClaimer` only migrates data
  that predates accounts. Kitchen never had a pre-account form, so it's
  intentionally skipped there — do **not** add a Kitchen branch to the claimer
  (adding one would be wrong, not just unnecessary).
- **Minor watch-out:** remember the two enumeration touch points that are easy to
  forget — `SYNC_COLLECTIONS` (backend) and `AccountDataEraser.scopedBaseKeys`
  (client). Missing the first = 400s on push; missing the second = a deleted
  account's pantry lingering on-device. Both are one-liners, both are listed in §4.
- **Out of scope confirmation:** quantities and expiry are explicitly deferred by
  this request. The model/payload can stay `{id, name, addedAt}`; adding
  `quantity`/`expiresAt` later is additive to the JSON payload with **no
  migration** (same reason the sync payload is schemaless), so deferring them
  costs nothing later.

---

## 4. Exact files to change / create

### Backend
- **Change** `app/db.py` — add `"kitchen"` to `SYNC_COLLECTIONS` (line 378). *(1 line)*
- **(optional) Change** `tests/test_sync.py` — add a kitchen push/pull case.

*(No new routes, tables, or migrations. `app/sync.py` is untouched — its
validator reads `db.SYNC_COLLECTIONS` dynamically.)*

### iOS — RecipeKit (`ios/RecipeKit/Sources/RecipeKit/`)
- **Create** `Models/PantryItem.swift` — the `Codable` model. *(new, ~30 lines)*
- **Create** `Storage/PantryStore.swift` — account-scoped `UserDefaults` store. *(new, ~60 lines)*
- **Change** `Sync/SyncModels.swift` — add `case kitchen` to `SyncCollection` (line 16).
- **Change** `Sync/LocalSyncApplier.swift` — add `PantryStore` to both inits
  (lines 29, 39), a `case .kitchen` to `apply` (line 53), and an `applyKitchen`
  helper.
- **Change** `Sync/AccountDataEraser.swift` — add `"pantry_items_v1"` to
  `scopedBaseKeys` (line 19).
- **(optional, if using a bespoke payload)** `Sync/SyncPayloads.swift` — only if
  you don't round-trip `PantryItem` directly; likely **not needed**.

### iOS — App (`ios/RecipeApp/`)
- **Create** `Providers/KitchenModel.swift` — observable view model. *(new, ~70 lines)*
- **Create** `Views/Main/KitchenView.swift` — the pantry screen. *(new, ~120–200 lines)*
- **Change** `Views/Main/MainTabView.swift` — add `Tab.kitchen` (line 36),
  construct `KitchenModel` in `init` (~line 39), add the tab's `NavigationStack` +
  `.tabItem` (~line 55). Also update the stale header comment (line 5) listing
  the tabs.

### Tests
- **Create** `ios/RecipeKit/Tests/RecipeKitTests/PantryStoreTests.swift` — mirror
  `CookbookStoreTests`.
- **Change** `ios/RecipeKit/Tests/RecipeKitTests/SyncStoreCodecTests.swift` — add
  a `PantryItem` round-trip.

### Xcode project
- **Change** `ios/RecipeApp.xcodeproj/project.pbxproj` — the new `.swift` files
  must be added to the RecipeApp target's Sources build phase (Xcode does this
  automatically when you add files via the IDE; noted so it isn't forgotten in a
  scripted/CLI add). RecipeKit files are picked up automatically by SwiftPM (glob),
  so no project edit is needed for the RecipeKit additions.

---

### Bottom line
Generic pattern confirmed on both sides. Kitchen is **~7 files created, ~6 files
touched** (most edits one-liners), no backend routes/tables/migrations, and the
string-list shape is a first-class fit. **Half a day for a functional version,
up to a full day with tests and a polished screen.**
