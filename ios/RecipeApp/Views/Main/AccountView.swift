//
//  AccountView.swift
//  RecipeApp
//
//  The Account/Settings screen. Deliberately uses NATIVE iOS settings styling
//  (inset-grouped List, system section headers, default row colors, gray SF
//  Symbols, native green Toggle) rather than the app's custom sage/cream/clay
//  card identity — this one screen is meant to read like Apple's Settings.
//  Functionality is unchanged; only the styling differs from the rest of the app.
//

import RecipeKit
import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var auth: AuthModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppAppearance.storageKey, store: .appGroup) private var appearance: AppAppearance = .system

    private var displayName: String {
        auth.currentUser?.fullName ?? auth.currentUser?.email ?? "Your account"
    }

    /// Drives the single "Dark Mode" switch. The stored preference keeps three
    /// states so first launch (`.system`) follows the OS; the toggle only ever
    /// writes an explicit override — ON → dark, OFF → light.
    private var darkModeBinding: Binding<Bool> {
        Binding(
            get: { appearance == .dark },
            set: { appearance = $0 ? .dark : .light }
        )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.headline)
                        if let email = auth.currentUser?.email, email != displayName {
                            Text(email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Signed in")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Appearance") {
                Toggle(isOn: darkModeBinding) {
                    Text("Dark Mode")
                }
                .tint(.green)  // native switch green, not the app's sage
            }

            Section("Feedback") {
                NavigationLink {
                    FeedbackView()
                } label: {
                    Text("Send Feedback")
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0 (mock)")
                LabeledContent("Recipes are", value: "Free & unlimited")
            }

            Section {
                Button(role: .destructive) {
                    auth.signOut()
                } label: {
                    Text("Sign Out")
                }
                // Account deletion (App Store Guideline 5.1.1) lands here in Stage 5.
            }

            #if DEBUG
            Section("Developer") {
                Button("Replay onboarding") {
                    hasCompletedOnboarding = false
                }
            }
            #endif
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Account")
    }
}

#Preview {
    NavigationStack {
        AccountView()
    }
    .environmentObject(AuthModel())
}
