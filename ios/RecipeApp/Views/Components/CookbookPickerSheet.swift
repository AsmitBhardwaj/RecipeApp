//
//  CookbookPickerSheet.swift
//  RecipeApp
//
//  Multi-select sheet for choosing which cookbook(s) a recipe belongs to. Used
//  from the recipe detail screen — the single place cookbook membership is
//  edited (assignment is entirely post-hoc; the Share Extension and Add flow
//  never prompt). Toggling is local until "Done" saves via CookbooksModel.
//

import SwiftUI
import RecipeKit

struct CookbookPickerSheet: View {
    let recipeId: String
    @ObservedObject var cookbooks: CookbooksModel
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    @State private var showingNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if cookbooks.cookbooks.isEmpty {
                        Text("No cookbooks yet. Create one below.")
                            .foregroundStyle(Color.textSecondary)
                    } else {
                        ForEach(cookbooks.cookbooks) { cookbook in
                            Button {
                                toggle(cookbook.id)
                            } label: {
                                HStack {
                                    Text(cookbook.name)
                                        .foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    if selected.contains(cookbook.id) {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New Cookbook", systemImage: "plus")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .appBackground()
            .navigationTitle("Add to Cookbook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                }
            }
            .alert("New Cookbook", isPresented: $showingNew) {
                TextField("Name", text: $newName)
                Button("Create") {
                    if let created = cookbooks.createCookbook(named: newName) {
                        selected.insert(created.id)
                    }
                    newName = ""
                }
                Button("Cancel", role: .cancel) { newName = "" }
            }
        }
        .onAppear { selected = cookbooks.cookbookIds(for: recipeId) }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func save() {
        cookbooks.setCookbooks(for: recipeId, to: selected)
        dismiss()
    }
}
