//
//  AccountView.swift
//  RecipeApp
//
//  The Account tab. A placeholder shell for this pass — real user identity,
//  settings, and auth are out of scope until networking is wired up.
//

import SwiftUI

struct AccountView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guest")
                            .font(.headline)
                        Text("Not signed in")
                            .font(.subheadline)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                .padding(.vertical, 6)
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
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .navigationTitle("Account")
    }
}

#Preview {
    NavigationStack {
        AccountView()
    }
}
