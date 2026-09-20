# Platter Pro paywall — remaining wiring

The paywall UI, copy, price math, presentation triggers, tests and previews are
complete on `feature/paywall-ui`, built entirely against protocols (no
RevenueCat, no StoreKit config, no backend changes — those are explicitly out of
this branch). This file lists exactly what the `feature/pro-entitlements` work
must provide to make it live.

## 1. Conform two real types to the paywall protocols

The UI depends only on these RecipeKit protocols (`Sources/RecipeKit/Paywall/`),
never on RevenueCat:

| Protocol | Real implementation must… |
|---|---|
| `EntitlementProviding` (`@MainActor`) | `EntitlementManager`: expose `isPro`, `freeImportLimit`, `freeImportsRemaining` from the entitlement API, and `refresh()` re-pulls after a purchase/restore. |
| `PaywallPurchasing` (`@MainActor`) | A RevenueCat-backed type: `loadOffering()` maps the current offering's `platter_pro_annual` + `platter_pro_monthly` packages into `PaywallPlan`/`PaywallOffering`; `purchase(_:)` maps a RevenueCat purchase to `.success` / `.cancelled` (userCancelled → `.cancelled`, **not** an error); `restore()` → `.restored` / `.nothingToRestore`. |

The `PaywallPlan` fields come straight from the store — **do not hardcode**:
`localizedPrice` = package `localizedPriceString`; `price`/`currencyCode` from
the `StoreProduct`; `introTrialDays` from the intro offer; `isTrialEligible`
from **intro-offer eligibility** (`checkTrialOrIntroDiscountEligibility` /
RevenueCat's eligibility API). Monthly must always be `introTrialDays: nil`,
`isTrialEligible: false` (no trial on monthly).

## 2. The single swap point

`ios/RecipeApp/Providers/PaywallCenter.swift` constructs the mocks today:

```swift
init(entitlements: any EntitlementProviding = MockEntitlementProvider(),
     purchasing:   any PaywallPurchasing   = MockPaywallPurchasing()) { … }
```

Replace those two defaults (or the `PaywallCenter()` call site in
`MainTabView`) with the real `EntitlementManager` + RevenueCat purchasing.
**Nothing else in the app changes** — every view already talks to the protocols.

## 3. Backend (separate branch)

`RecipeProviderError.quotaExceeded` / `.proRequired` are already mapped from
**HTTP 402** with `error_code` `"quota_exceeded"` / `"pro_required"`
(`APIRecipeProvider.send`). The backend must actually return 402 + that
`error_code` from `POST /v1/jobs` (quota) and `POST /v1/pantry/suggestions`
(pro-only). No client change needed when it does.

## 4. Presentation — already wired (against the protocols)

- **Import limit:** `AddRecipeView` catches `.quotaExceeded` → `PaywallCenter.present(.importLimit)`.
- **Pantry:** `KitchenView.refreshSuggestions()` gates on `PaywallCenter.requirePro(trigger: .pantry)` — non-Pro users never hit the endpoint; the server `pro_required` path is a backstop via `PantrySuggestionsModel.onProRequired`.
- **Settings:** `AccountView` shows a "Platter Pro" row → `.settings`; Pro users see "Platter Pro · Manage subscription".
- **Extension:** `ShareRootView` shows "Open Platter to continue" on `.quotaExceeded` and deep-links `recipeapp://paywall`; `MainTabView.onOpenURL` presents `.importLimit`.

## 5. Known placeholders / TODOs

- **Terms link:** no `platterapp.tech/terms` page exists yet, so `PaywallLinks.terms` falls back to Apple's standard EULA (`https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`). Point it at the real page before submission. Privacy → `platterapp.tech/privacy` (confirm it's live).
- **Manage subscription:** `AccountView` opens `https://apps.apple.com/account/subscriptions` via `openURL`. The real Pro build should prefer StoreKit's `AppStore.showManageSubscriptions(in:)` for the in-app sheet.
- **Extension deep link:** uses `extensionContext.open(_:)`. If the host app blocks opening a custom scheme from a share extension, fall back to the responder-chain `UIApplication.open` workaround.
- **DEBUG screenshot hooks:** `RootView` reads `PAYWALL_PREVIEW` (and the onboarding branch's `UI_SCREENSHOT_MAIN`) — `#if DEBUG` only, compiled out of release. Remove if undesired.
- **"Recipes are: Free & unlimited"** copy in `AccountView`'s About section is now stale given Pro; update when Pro ships (left as-is here to keep this branch UI-scoped).

## 6. Manual tests to run once the SDK + StoreKit config exist

Use the local StoreKit configuration file (Xcode → Transaction Manager):

1. **Purchase (annual, trial-eligible):** CTA reads "Start 7-day free trial" → purchase → sheet dismisses, `EntitlementManager.isPro` true, imports unlocked.
2. **Purchase (monthly):** select Monthly → CTA "Subscribe for $Z/month" (no trial) → purchase succeeds.
3. **Cancel:** begin purchase, cancel in the StoreKit sheet → paywall stays, **no error shown**.
4. **Purchase error:** force a failure (Transaction Manager → fail) → inline error message, sheet stays.
5. **Restore (has sub):** Restore Purchases → "Purchases restored." → dismiss, Pro active.
6. **Restore (none):** clear transactions → Restore → "No active subscription found." (stays open).
7. **Expired / not trial-eligible:** consume the intro offer (or expire the sub) → trial line hidden, CTA becomes "Subscribe for $Y/year"; fine print drops "days free".
8. **Trigger copy:** verify import-limit vs pantry vs settings headline/subhead + benefit order.
9. **Price/savings:** confirm the annual "$X/month" and "SAVE N%" pill match the real store prices (and the pill hides if annual isn't cheaper).
