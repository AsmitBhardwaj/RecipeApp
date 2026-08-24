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

import SwiftUI

struct AccountView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppAppearance.storageKey, store: .appGroup) private var appearance: AppAppearance = .system

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
                        Text("Guest")
                            .font(.headline)
                        Text("Not signed in")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Appearance") {
                Toggle(isOn: darkModeBinding) {
                    Label {
                        Text("Dark Mode")
                    } icon: {
                        Image(systemName: "moon.stars").foregroundStyle(.secondary)
                    }
                }
                .tint(.green)  // native switch green, not the app's sage
            }

            Section("Feedback") {
                NavigationLink {
                    FeedbackView()
                } label: {
                    Label {
                        Text("Send Feedback")
                    } icon: {
                        Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0 (mock)")
                LabeledContent("Recipes are", value: "Free & unlimited")
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
}
