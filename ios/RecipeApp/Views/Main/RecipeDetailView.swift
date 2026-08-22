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
    @StateObject private var scaler: ServingScaler

    init(recipe: Recipe) {
        self.recipe = recipe
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
        RecipeImageView(imageUrl: recipe.imageUrl, fallbackSeed: recipe.recipeId, placeholderSymbolSize: 52)
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
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(.tint)
                            .frame(width: 6, height: 6)
                            .padding(.top, 7)
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
        RecipeDetailView(recipe: .spicyNoodles)
    }
}

#Preview("Generated, no image") {
    NavigationStack {
        RecipeDetailView(recipe: .margheritaPizza)
    }
}
