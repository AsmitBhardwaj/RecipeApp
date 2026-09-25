//
//  RecipeApp.swift
//  RecipeApp
//
//  App entry point. Constructs the single `RecipeProvider` and hands it to the
//  UI. The live app uses `APIRecipeProvider` (real backend); swap to
//  `MockRecipeProvider()` for offline/preview work.
//

import SwiftUI
import RecipeKit

@main
struct RecipeApp: App {
    /// Owns the `UNUserNotificationCenter` delegate so Cook Mode timer alerts
    /// present while the app is foregrounded (the common Cook Mode case).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The app-wide data source. Injected down into the views that need it.
    /// Live networking against the Railway backend.
    private let recipeProvider: RecipeProvider

    /// The app-wide auth session. Owns the signed-in state, persists tokens in
    /// the shared Keychain, and (Stage 2b) vends access tokens to the sync engine.
    @StateObject private var auth: AuthModel
    /// The single StoreKit 2 source of truth for products and Pro entitlement.
    @StateObject private var subscriptions: SubscriptionService

    /// Cook Mode step-timer notification scheduler, backed by the real
    /// `UNUserNotificationCenter`. One instance for the app; Cook Mode sessions
    /// borrow it (see `CookModeModel`).
    private let cookTimerScheduler = CookTimerNotificationScheduler(
        center: UNCookTimerNotificationScheduling()
    )

    init() {
        let auth = AuthModel()
        // Stamp purchases with the signed-in account's UUID (appAccountToken) so the
        // backend binds the subscription to this account.
        let subscriptions = SubscriptionService(
            accountUUID: { [weak auth] in
                guard let id = auth?.session?.user.id else { return nil }
                return AccountUUID.from(id)
            }
        )
        _subscriptions = StateObject(wrappedValue: subscriptions)
        // Wipe entitlement caches whenever the session is torn down, so a prior
        // account's Pro status can't leak into the next account on this device.
        auth.onSessionCleared = { await subscriptions.resetForAccountChange() }
        _auth = StateObject(wrappedValue: auth)
        // Pro is server-verified per account now — the provider sends no Pro header.
        recipeProvider = APIRecipeProvider()
        // Register the bundled editorial display font before any UI renders.
        AppFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let forced = Self.debugForcedPaywallContent {
                    // Screenshot/QA harness: launch straight into the paywall in a
                    // fixed state via `-paywallState ready|loading|unavailable`.
                    PlatterProPaywallView(forcedContent: forced)
                        .environmentObject(subscriptions)
                } else if let gate = debugGateView() {
                    gate
                } else {
                    root
                }
                #else
                root
                #endif
            }
        }
    }

    private var root: some View {
        RootView(recipeProvider: recipeProvider, auth: auth, subscriptions: subscriptions)
            .environmentObject(auth)
            .environmentObject(subscriptions)
            .environment(\.cookTimerScheduler, cookTimerScheduler)
            .task { await subscriptions.start() }
    }

    #if DEBUG
    /// Reads `-paywallState <ready|loading|unavailable>` from the launch
    /// arguments so the three paywall states can be launched and screenshotted in
    /// the simulator. Ready uses obvious sample prices — this is a QA harness, not
    /// production pricing (production maps `Product.displayPrice`).
    private static var debugForcedPaywallContent: PlanContent? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-paywallState"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "ready":
            return .ready([.sampleYearly, .sampleMonthly])
        case "loading": return .loading
        case "unavailable": return .unavailable
        default: return nil
        }
    }

    /// Renders a single Pro-gated screen with a forced cached entitlement, so the
    /// free and Pro states can be screenshotted without signing in or seeding
    /// data. Launch with `-gatePreview nutritionFree|nutritionPro|pantryFree|pantryPro`.
    /// Sets only the App-Group cache (which drives `isProUnlocked`) — no StoreKit
    /// or purchase state is touched.
    private func debugGateView() -> AnyView? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-gatePreview"), i + 1 < args.count else { return nil }
        let mode = args[i + 1]
        // "…Free" → locked; anything else (…Pro, budgetResults) → entitled.
        ProEntitlementCache.set(!mode.hasSuffix("Free"))
        let inner: AnyView
        switch mode {
        case "nutritionFree", "nutritionPro":
            inner = AnyView(NavigationStack {
                RecipeDetailView(recipe: .spicyNoodles, cookbooks: CookbooksModel())
            })
        case "pantryFree", "pantryPro":
            inner = AnyView(NavigationStack {
                KitchenView(cookbooks: CookbooksModel())
            })
        case "mealPlan":
            // Screenshot harness for the Meal Plan tab header (title row + segmented
            // control). Mock-backed models so it renders without sign-in or data.
            inner = AnyView(
                NavigationStack {
                    MealPlanView(
                        jobs: PendingJobsModel(provider: MockRecipeProvider(), userScope: "preview"),
                        cookbooks: CookbooksModel(userScope: "preview"),
                        userScope: "preview"
                    )
                }
                .environmentObject(CookingPreferencesModel(userScope: "preview"))
            )
        case "onboardingPrefs", "onboardingRegion":
            // Screenshot harness for the onboarding preferences (Screen 4) and the
            // new grocery-region (Screen 5) steps, jumped to directly.
            let startPage = mode == "onboardingRegion" ? 4 : 3
            inner = AnyView(
                OnboardingView(auth: auth, initialPage: startPage)
                    .environmentObject(CookingPreferencesModel(userScope: "preview"))
            )
        case "budgetFree", "budgetPro", "budgetResults":
            inner = AnyView(NavigationStack {
                BudgetPlanContainer(
                    householdSize: 2,
                    dietary: [],
                    pantryNames: { ["rice", "eggs", "spinach"] },
                    generate: { _, _, _, _ in Self.sampleBudgetPlan() },
                    commit: { _ in },
                    onSaved: {},
                    autoGenerate: mode == "budgetResults"
                )
                .environmentObject(CookingPreferencesModel(userScope: "preview"))
            })
        default:
            return nil
        }
        return AnyView(inner
            .environmentObject(subscriptions)
            .environment(\.cookTimerScheduler, cookTimerScheduler))
    }

    /// Sample budget plan for the `-gatePreview budgetResults` screenshot harness.
    private static func sampleBudgetPlan() -> BudgetPlanResponse {
        func recipe(_ id: String, _ title: String) -> Recipe {
            Recipe(
                recipeId: id, canonicalVideoId: "budget:\(id)", title: title,
                servings: Servings(amount: 2, unit: nil), prepTimeMinutes: nil,
                cookTimeMinutes: nil, totalTimeMinutes: nil, ingredients: [], instructions: [],
                confidence: nil, sourceType: .generated, imageUrl: nil, imageSource: .none, transcript: nil
            )
        }
        let items: [(String, String, Double, String)] = [
            ("b1", "Chickpea & Spinach Curry", 8, "High fiber, veg-forward"),
            ("b2", "Egg Fried Rice", 6, "Quick, balanced"),
            ("b3", "Lentil Soup", 7, "High protein, low fat"),
            ("b4", "Veggie Pasta Bake", 9, "Comfort, veg-forward"),
        ]
        let planned = items.map { id, title, cost, health in
            PlannedRecipe(recipe: recipe(id, title), estimatedCost: CostEstimate(amount: cost), healthSignal: health)
        }
        return BudgetPlanResponse(recipes: planned, currency: "USD", budget: 75, minBudget: 50, regionalMultiplier: 1.0)
    }
    #endif
}
