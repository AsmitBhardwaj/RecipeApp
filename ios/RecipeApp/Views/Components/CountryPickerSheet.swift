//
//  CountryPickerSheet.swift
//  RecipeApp
//
//  A searchable, single-select list of every ISO country, used by onboarding and
//  Account to capture the user's grocery-cost country. Selection is stored as an
//  ISO 3166-1 alpha-2 code (see RecipeKit.GroceryCountry); the backend applies a
//  real cost baseline for known countries and a 1.0 default for the rest.
//

import SwiftUI
import RecipeKit

struct CountryPickerSheet: View {
    /// The currently-selected ISO alpha-2 code (nil = none chosen yet).
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let countries = GroceryCountry.all()

    private var filtered: [(code: String, name: String)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return countries }
        return countries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.code) { country in
                Button {
                    selection = country.code
                    dismiss()
                } label: {
                    HStack {
                        Text(country.name)
                            .foregroundStyle(Color.textPrimary)
                        Spacer(minLength: 12)
                        if selection == country.code {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .fontWeight(.semibold)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search countries")
            .navigationTitle("Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
