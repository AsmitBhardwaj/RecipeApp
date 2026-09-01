//
//  RecipeDetailView.swift
//  RecipeApp
//
//  Full recipe view: hero image (graceful fallback if none), title, meta
//  (servings + prep/cook/total), ingredients, and numbered instructions.
//  Generated recipes and image provenance are badged (CLAUDE.md §5).
//

import SwiftUI
import RecipeKit

struct RecipeDetailView: View {
    let recipe: Recipe
    @ObservedObject var cookbooks: CookbooksModel
    /// Account scope for the per-user Cook Mode timer store (nil in previews).
    let userScope: String?
    @StateObject private var scaler: ServingScaler
    @State private var showingCookbookPicker = false
    @State private var showingCookMode = false
    /// App-wide step-timer notification scheduler, injected at the app root.
    @Environment(\.cookTimerScheduler) private var cookTimerScheduler

    init(recipe: Recipe, cookbooks: CookbooksModel, userScope: String? = nil) {
        self.recipe = recipe
        self.cookbooks = cookbooks
        self.userScope = userScope
        // Base is only meaningful when scalable; when it isn't, the scaler is
        // never surfaced, so a placeholder of 1 is harmless.
        _scaler = StateObject(wrappedValue: ServingScaler(baseServings: recipe.baseServings ?? 1))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if recipe.canScaleServings {
                        HStack {
                            Spacer(minLength: 0)
                            servingAdjuster
                        }
                    }
                    metaRow
                    if !recipe.instructions.isEmpty {
                        startCookingButton
                    }
                    cookbooksSection
                    ingredientsSection
                    instructionsSection
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 32)
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        // Full-screen cover (not a sheet) so a stray swipe can't drop the cook.
        .fullScreenCover(isPresented: $showingCookMode) {
            CookModeView(recipe: recipe, userScope: userScope, scheduler: cookTimerScheduler)
        }
    }

    // MARK: Start Cooking

    /// Primary entry point into the full-screen guided Cook Mode. Shown only when
    /// the recipe actually has steps (guarded at the call site).
    private var startCookingButton: some View {
        Button {
            showingCookMode = true
        } label: {
            Label("Start Cooking", systemImage: "flame.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: Serving-size adjuster

    /// +/- control that scales ingredient quantities. Shown only when
    /// `recipe.canScaleServings` (numeric base + at least one numeric quantity);
    /// see ServingScaler / RecipeKit's `Recipe.canScaleServings`. When shown, it
    /// OWNS the servings display, so `metaItems` drops its static "Servings" cell
    /// to avoid showing the count twice.
    ///
    /// Deliberately a lightweight inline stepper — no torn-edge card — so it
    /// reads as a small utility next to the title, not a boxed feature.
    private var servingAdjuster: some View {
        HStack(spacing: 10) {
            stepButton("minus", enabled: scaler.canDecrement, action: scaler.decrement)
            VStack(spacing: 0) {
                Text("\(scaler.currentServings.quantityString) \(scaler.currentServings == 1 ? "serving" : "servings")")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                if scaler.isScaled {
                    Text("originally \(scaler.baseServings.quantityString)")
                        .font(.caption2)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            stepButton("plus", enabled: scaler.canIncrement, action: scaler.increment)
        }
    }

    /// A small sage circular +/- button. Lighter than the instruction step
    /// numbers — this is an inline utility control, not content.
    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    enabled ? Color.accentColor : Color.textSecondary.opacity(0.3),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Hero image

    private var hero: some View {
        RecipeImageView(imageUrl: recipe.imageUrl, fallbackSeed: recipe.recipeId, fallbackTitle: recipe.title, placeholderSymbolSize: 52)
            .frame(height: 240)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                ImageSourceBadge(source: recipe.imageSource)
                    .padding(10)
            }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recipe.isGenerated {
                GeneratedBadge()
            }
            Text(recipe.title)
                .font(.editorialTitle(size: 30, relativeTo: .largeTitle))
            if recipe.isGenerated {
                Text("This recipe was generated from general culinary knowledge, not extracted from the video.")
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    // MARK: Meta (servings + times)

    private var metaRow: some View {
        let items = metaItems
        return Group {
            if !items.isEmpty {
                HStack(spacing: 12) {
                    ForEach(items, id: \.label) { item in
                        VStack(spacing: 4) {
                            Text(item.value)
                                .font(.subheadline.weight(.semibold))
                            Text(item.label)
                                .font(.caption2)
                                .foregroundStyle(Color.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                .tornEdgeCard()
            }
        }
    }

    private var metaItems: [(label: String, value: String)] {
        var items: [(String, String)] = []
        // When the adjuster is shown it owns the servings display, so skip the
        // static cell here to avoid showing the count twice.
        if !recipe.canScaleServings, let servings = recipe.servings.displayString {
            items.append(("Servings", servings))
        }
        if let prep = recipe.prepTimeMinutes {
            items.append(("Prep", prep.minutesString))
        }
        if let cook = recipe.cookTimeMinutes {
            items.append(("Cook", cook.minutesString))
        }
        if let total = recipe.totalTimeMinutes {
            items.append(("Total", total.minutesString))
        }
        return items
    }

    // MARK: Cookbooks

    /// Post-hoc cookbook assignment — the single place membership is edited
    /// (import flows never prompt). Shows the recipe's current cookbooks as chips
    /// and opens the multi-select picker.
    private var cookbooksSection: some View {
        let assignedIds = cookbooks.cookbookIds(for: recipe.recipeId)
        let assigned = cookbooks.cookbooks.filter { assignedIds.contains($0.id) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Cookbooks", systemImage: "books.vertical")
                Spacer()
                Button {
                    showingCookbookPicker = true
                } label: {
                    Label(assigned.isEmpty ? "Add" : "Edit", systemImage: "plus.circle")
                        .font(.subheadline.weight(.semibold))
                }
            }
            if assigned.isEmpty {
                Text("In All Recipes only — tap Add to file it into a cookbook.")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(assigned) { cookbook in
                            Text(cookbook.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.textSecondary.opacity(0.10), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.cardEdge, lineWidth: 1))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingCookbookPicker) {
            CookbookPickerSheet(recipeId: recipe.recipeId, cookbooks: cookbooks)
        }
    }

    // MARK: Ingredients

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Ingredients", systemImage: "carrot")
            if recipe.ingredients.isEmpty {
                Text("No ingredients listed.")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            } else {
                ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, ingredient in
                    HStack(alignment: .center, spacing: 12) {
                        // Same photo/emoji icon the item shows on the Grocery List.
                        IngredientIconGlyph(name: ingredient.name, size: 28)
                            .accessibilityHidden(true)
                        Text(ingredientLine(for: ingredient))
                            .font(.body)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// Scales the ingredient line when the adjuster is active; otherwise the
    /// plain line. Ingredients without a numeric quantity are unchanged either
    /// way (handled inside `displayString(scaledBy:)`).
    private func ingredientLine(for ingredient: Ingredient) -> String {
        recipe.canScaleServings
            ? ingredient.displayString(scaledBy: scaler.ratio)
            : ingredient.displayString
    }

    // MARK: Instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Instructions", systemImage: "list.number")
            if recipe.instructions.isEmpty {
                Text("No instructions listed.")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            } else {
                ForEach(recipe.instructions) { step in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(step.stepNumber)")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.tint, in: Circle())
                        Text(step.text)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.title3.bold())
    }
}

#Preview("Full recipe") {
    NavigationStack {
        RecipeDetailView(recipe: .spicyNoodles, cookbooks: CookbooksModel())
    }
}

#Preview("Generated, no image") {
    NavigationStack {
        RecipeDetailView(recipe: .margheritaPizza, cookbooks: CookbooksModel())
    }
}
