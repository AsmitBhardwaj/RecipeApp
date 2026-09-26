import RecipeKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var auth: AuthModel
    @EnvironmentObject private var preferences: CookingPreferencesModel
    @EnvironmentObject private var subscriptions: SubscriptionService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var sync: SyncCoordinator
    @StateObject private var pantry: PantryModel
    @StateObject private var suggestions = PantrySuggestionsModel()

    @State private var page = 0
    @State private var primaryGoal: PrimaryCookingGoal?
    @State private var dietaryPreferences: Set<DietaryPreference> = []
    @State private var householdSize = 2
    @State private var country: String?
    @State private var areaType: AreaType?
    @State private var pantrySelections: Set<String> = []
    @State private var hasLoadedAnswers = false
    @State private var showingPaywall = false

    private let pageCount = 6
    /// The pantry step is the last screen; its suggestion fetch keys off this index.
    private let pantryPage = 5

    init(auth: AuthModel, initialPage: Int = 0) {
        self.auth = auth
        let userID = auth.currentUser?.id ?? "unknown"
        let coordinator = SyncCoordinator(userId: userID, tokenProvider: { try await auth.validAccessToken() })
        _sync = StateObject(wrappedValue: coordinator)
        _pantry = StateObject(wrappedValue: PantryModel(userScope: userID, sync: coordinator))
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        ZStack {
            switch page {
            case 0: OnboardingValueScreen()
            case 1: OnboardingSavingScreen()
            case 2: OnboardingGoalScreen(selection: $primaryGoal)
            case 3:
                OnboardingPreferencesScreen(
                    dietaryPreferences: $dietaryPreferences,
                    householdSize: $householdSize
                )
            case 4:
                OnboardingRegionScreen(country: $country, areaType: $areaType)
            default:
                OnboardingPantryScreen(
                    selections: $pantrySelections,
                    suggestion: suggestions.matches.first ?? suggestions.generated.first,
                    isLoading: suggestions.isInitialLoading
                )
            }
        }
        .id(page)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .background(Color.creamTint.ignoresSafeArea())
        .foregroundStyle(Color.textPrimary)
        .onAppear(perform: loadExistingAnswers)
        .onChange(of: pantrySelections) { _, names in
            guard page == pantryPage else { return }
            suggestions.refresh(pantryNames: names.sorted(), via: sync, debounce: .milliseconds(350))
        }
        .onChange(of: page) { _, newPage in
            if newPage == pantryPage {
                suggestions.refresh(pantryNames: pantrySelections.sorted(), via: sync)
            }
        }
        .sheet(isPresented: $showingPaywall, onDismiss: completeOnboarding) {
            PlatterProPaywallView()
                .environmentObject(subscriptions)
        }
    }

    private var header: some View {
        ZStack {
            HStack {
                if page == 0 {
                    PlatterMark(size: 36)
                        .accessibilityLabel("Platter")
                } else {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.surface, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                Spacer()
            }

            HStack {
                Spacer()
                Button("Skip", action: finish)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Finishes onboarding without requiring more answers")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color.creamTint)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            OnboardingPageDots(current: page, total: pageCount)
            OnboardingPrimaryButton(
                title: page == pageCount - 1 ? "Start cooking" : "Continue",
                isEnabled: page != 2 || primaryGoal != nil,
                action: page == pageCount - 1 ? finish : advance
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color.creamTint)
    }

    private func loadExistingAnswers() {
        guard !hasLoadedAnswers else { return }
        hasLoadedAnswers = true
        primaryGoal = preferences.primaryGoal
        dietaryPreferences = preferences.dietaryPreferences
        householdSize = preferences.householdSize
        // Prefill a stored country; on a first run with none, guess from device
        // locale so the picker starts on a sensible country the user can change.
        // Area type has no sensible locale guess, so it stays unset until picked.
        country = preferences.country ?? GroceryCountry.guessFromLocale()
        areaType = preferences.areaType
        let existing = Set(pantry.items.map { $0.name.lowercased() })
        pantrySelections = Set(OnboardingPantryScreen.staples.filter { existing.contains($0.lowercased()) })
    }

    private func advance() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            page = min(page + 1, pageCount - 1)
        }
    }

    private func goBack() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            page = max(page - 1, 0)
        }
    }

    private func finish() {
        preferences.saveAnswers(
            primaryGoal: primaryGoal,
            dietaryPreferences: dietaryPreferences,
            householdSize: householdSize,
            country: country,
            areaType: areaType
        )
        let existing = Set(pantry.items.map { $0.name.lowercased() })
        for item in pantrySelections where !existing.contains(item.lowercased()) {
            pantry.add(name: item)
        }
        sync.triggerSync()

        // Keep onboarding mounted while the paywall is presented. Marking it
        // complete first would make SignedInRoot replace this view immediately,
        // preventing the sheet from appearing.
        if subscriptions.isProUnlocked {
            completeOnboarding()
        } else {
            // Final onboarding step: present the paywall once (trigger .onboarding),
            // dismissible immediately. Mark it so the periodic app-open paywall is
            // not also shown in this same session.
            subscriptions.markOnboardingPaywallShown()
            showingPaywall = true
        }
    }

    private func completeOnboarding() {
        preferences.completeOnboarding()
    }
}

#Preview {
    OnboardingView(auth: AuthModel())
        .environmentObject(CookingPreferencesModel(userScope: "preview"))
        .environmentObject(SubscriptionService())
}
