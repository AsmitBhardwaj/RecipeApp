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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                VStack(alignment: .leading, spacing: 24) {
                    header
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

    // MARK: Hero image

    private var hero: some View {
        RecipeImageView(imageUrl: recipe.imageUrl, placeholderSymbolSize: 52)
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
                .font(.title.bold())
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
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Color.borderWarm.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var metaItems: [(label: String, value: String)] {
        var items: [(String, String)] = []
        if let servings = recipe.servings.displayString {
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
                        Text(ingredient.displayString)
                            .font(.body)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
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
