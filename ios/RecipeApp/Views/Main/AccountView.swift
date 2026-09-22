//
//  AccountView.swift
//  RecipeApp
//
//  The Account/Settings screen. Uses the app's cream background and adaptive
//  surface cards rather than Form/List chrome; actions and state remain unchanged.
//

import RecipeKit
import SwiftUI

struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var auth: AuthModel
    @EnvironmentObject private var subscriptions: SubscriptionService
    @EnvironmentObject private var cookingPreferences: CookingPreferencesModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppAppearance.storageKey, store: .appGroup) private var appearance: AppAppearance = .system

    @State private var showDeleteConfirm = false
    @State private var deleteError: String?
    @State private var showPaywall = false

    /// Drives the single "Dark Mode" switch. The stored preference keeps three
    /// states so first launch (`.system`) follows the OS; the toggle only ever
    /// writes an explicit override — ON → dark, OFF → light.
    private var darkModeBinding: Binding<Bool> {
        Binding(
            get: { appearance == .dark },
            set: { appearance = $0 ? .dark : .light }
        )
    }

    private var regionBinding: Binding<GroceryRegion?> {
        Binding(
            get: { cookingPreferences.region },
            set: { cookingPreferences.updateRegion($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    settingsSection("Platter Pro") {
                        SettingsCard {
                            Button(action: openPlatterPro) {
                                SettingsRowContent(icon: "sparkles", title: "Platter Pro") {
                                    HStack(spacing: Theme.Spacing.sm) {
                                        Text(subscriptions.settingsStatusText)
                                            .font(.subheadline)
                                            .foregroundStyle(Color.textSecondary)
                                        SettingsChevron()
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Platter Pro, \(subscriptions.settingsStatusText)")
                            .accessibilityHint(
                                subscriptions.hasProAccess
                                    ? "Opens Apple subscription management"
                                    : "Opens Platter Pro plans"
                            )
                        }
                    }

                    settingsSection("Cooking Preferences") {
                        SettingsCard {
                            SettingsRowContent(icon: "person.2", title: "Cooking for") {
                                HStack(spacing: 18) {
                                    stepperButton("minus", enabled: cookingPreferences.householdSize > 1) {
                                        cookingPreferences.updateHouseholdSize(cookingPreferences.householdSize - 1)
                                    }
                                    Text("\(cookingPreferences.householdSize)")
                                        .font(.body.weight(.semibold)).monospacedDigit().frame(minWidth: 22)
                                        .accessibilityLabel("\(cookingPreferences.householdSize) people")
                                    stepperButton("plus", enabled: cookingPreferences.householdSize < 12) {
                                        cookingPreferences.updateHouseholdSize(cookingPreferences.householdSize + 1)
                                    }
                                }
                            }
                            SettingsDivider()
                            Menu {
                                Picker("Region", selection: regionBinding) {
                                    Text("Not set").tag(GroceryRegion?.none)
                                    ForEach(GroceryRegion.allCases, id: \.self) { region in
                                        Text(region.displayName).tag(GroceryRegion?.some(region))
                                    }
                                }
                            } label: {
                                SettingsRowContent(icon: "cart", title: "Grocery region") {
                                    HStack(spacing: Theme.Spacing.sm) {
                                        Text(cookingPreferences.region?.displayName ?? "Not set")
                                            .font(.subheadline)
                                            .foregroundStyle(Color.textSecondary)
                                            .lineLimit(1)
                                        SettingsChevron()
                                    }
                                }
                            }
                            .accessibilityLabel("Grocery region, \(cookingPreferences.region?.displayName ?? "Not set")")
                            .accessibilityHint("Sets realistic budgets when planning meals")
                        }
                    }

                    settingsSection("Appearance") {
                        SettingsCard {
                            Toggle(isOn: darkModeBinding) {
                                SettingsRowContent(icon: "moon", title: "Dark Mode")
                            }
                            .tint(Theme.accent)
                            .padding(.trailing, 16)
                        }
                    }

                    settingsSection("Feedback") {
                        SettingsCard {
                            NavigationLink {
                                FeedbackView()
                            } label: {
                                SettingsRowContent(icon: "envelope", title: "Send Feedback") {
                                    SettingsChevron()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    settingsSection("About") {
                        SettingsCard {
                            SettingsValueRow(icon: "number", title: "Version", value: "1.0 (mock)")
                            SettingsDivider()
                            SettingsValueRow(icon: "fork.knife", title: "Recipes are", value: "Free & unlimited")
                        }
                    }

                    settingsSection("Account") {
                        VStack(spacing: 14) {
                            SettingsCard {
                                SettingsActionRow(icon: "rectangle.portrait.and.arrow.right",
                                                  title: "Sign Out", destructive: true) {
                                    auth.signOut()
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                SettingsCard {
                                    SettingsActionRow(icon: "trash", title: "Delete Account", destructive: true) {
                                        showDeleteConfirm = true
                                    }
                                }

                                Text("Permanently deletes your account and all your recipes, cookbooks, meal plans, and lists on every device.")
                                    .font(.footnote)
                                    .foregroundStyle(Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 4)
                            }
                        }
                    }

                    #if DEBUG
                    settingsSection("Developer") {
                        SettingsCard {
                            SettingsActionRow(icon: "arrow.counterclockwise", title: "Replay onboarding") {
                                replayOnboarding()
                            }
                        }
                    }
                    #endif
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
        }
        .foregroundStyle(Color.textPrimary)
        .background(Color.creamTint.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .disabled(auth.isWorking)
        .sheet(isPresented: $showPaywall) {
            PlatterProPaywallView()
                .environmentObject(subscriptions)
        }
        .task { await subscriptions.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await subscriptions.refreshEntitlement() }
            }
        }
        .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Your account and all your recipes, cookbooks, meal plans, and lists will be permanently deleted.")
        }
        .alert(
            "Couldn't delete account",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .alert(
            "Couldn't open subscriptions",
            isPresented: Binding(
                get: { subscriptions.managementError != nil },
                set: { if !$0 { subscriptions.clearManagementError() } }
            )
        ) {
            Button("OK", role: .cancel) { subscriptions.clearManagementError() }
        } message: {
            Text(subscriptions.managementError ?? "")
        }
    }

    private var header: some View {
        ZStack {
            Text("My account.")
                .font(.editorialTitle(size: 24, relativeTo: .title2))
                .foregroundStyle(Color.textPrimary)

            HStack {
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Color.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .padding(.leading, 4)

            content()
        }
    }

    private func deleteAccount() {
        Task {
            do {
                try await auth.deleteAccount()
                // Success: `auth.session` is now nil, so RootView swaps to SignInView.
            } catch {
                deleteError = (error as? AuthError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func replayOnboarding() {
        // Dismiss this sheet first, then let RootView replace the main app with a
        // fresh onboarding instance. No account-scoped data is touched.
        dismiss()
        hasCompletedOnboarding = false
    }

    private func stepperButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Color.creamTint, in: Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(systemImage == "plus" ? "Increase household size" : "Decrease household size")
    }

    private func openPlatterPro() {
        if subscriptions.hasProAccess {
            Task { await subscriptions.showSubscriptionManagement() }
        } else {
            subscriptions.clearPurchaseMessage()
            showPaywall = true
        }
    }
}

// MARK: - Custom settings components

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct SettingsRowContent<Trailing: View>: View {
    let icon: String
    let title: String
    let titleColor: Color
    @ViewBuilder let trailing: () -> Trailing

    init(
        icon: String,
        title: String,
        titleColor: Color = .textPrimary,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.titleColor = titleColor
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(titleColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.body)
                .foregroundStyle(titleColor)

            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private extension SettingsRowContent where Trailing == EmptyView {
    init(icon: String, title: String, titleColor: Color = .textPrimary) {
        self.init(icon: icon, title: title, titleColor: titleColor) { EmptyView() }
    }
}

private struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.textSecondary.opacity(0.65))
            .accessibilityHidden(true)
    }
}

private struct SettingsValueRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        SettingsRowContent(icon: icon, title: title) {
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsActionRow: View {
    let icon: String
    let title: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            SettingsRowContent(
                icon: icon,
                title: title,
                titleColor: destructive ? .red : .textPrimary
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.hairline)
            .padding(.leading, 53)
    }
}

#Preview {
    NavigationStack {
        AccountView()
    }
    .environmentObject(AuthModel())
    .environmentObject(SubscriptionService())
    .environmentObject(CookingPreferencesModel(userScope: "preview"))
}
