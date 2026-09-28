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
    /// Whether the hero's real photo (not the bundled fallback) is actually on
    /// screen — drives `ImageSourceBadge` (RecipeDetailView 1.1 Step 3).
    @State private var isHeroPhotoLoaded = false
    /// Nutrition (calories/macros) is a Platter Pro feature. The server (not
    /// this cached entitlement) decides free-vs-Pro per recipe via
    /// `recipe.nutrition` / `recipe.nutritionLocked` — this object is only
    /// needed to present the paywall sheet when the locked card is tapped.
    @EnvironmentObject private var subscriptions: SubscriptionService
    @State private var showPaywall = false
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
                    cookAndServingsRow
                    nutritionSection
                    sourceAttributionRow
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
        .sheet(isPresented: $showPaywall) {
            PlatterProPaywallView()
                .environmentObject(subscriptions)
        }
    }

    // MARK: Start Cooking

    /// Primary entry point into the full-screen guided Cook Mode. Shown only when
    /// the recipe actually has steps (guarded at the call site).
    private var startCookingButton: some View {
        Button {
            showingCookMode = true
        } label: {
            Text("Start Cooking")
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
    /// see ServingScaler / RecipeKit's `Recipe.canScaleServings`. It sits on the
    /// right of `cookAndServingsRow` and OWNS the servings display there; a
    /// non-scalable recipe shows a static serving count in its place instead.
    ///
    /// Deliberately a lightweight inline stepper — no torn-edge card — so it
    /// reads as a small utility next to the cook time, not a boxed feature.
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
        RecipeImageView(
            imageUrl: recipe.imageUrl,
            fallbackSeed: recipe.recipeId,
            fallbackTitle: recipe.title,
            placeholderSymbolSize: 52,
            onPhotoLoadedChange: { isHeroPhotoLoaded = $0 }
        )
            .frame(height: 240)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                ImageSourceBadge(source: recipe.imageSource, isPhotoLoaded: isHeroPhotoLoaded)
                    .padding(10)
            }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // No generated-recipe UI is rendered here (the badge and the
            // explanatory note were removed); the model's `isGenerated` flag is
            // retained so this can be reinstated later.
            Text(recipe.title)
                .font(.editorialTitle(size: 30, relativeTo: .largeTitle))
        }
    }

    /// Single full-width tappable row that opens the recipe's original source
    /// URL in Safari. Hidden when the recipe has no (trustworthy, http/https)
    /// source URL — e.g. pasted text. Replaces the old creator/title/thumbnail/
    /// domain source UI entirely (RecipeDetailView 1.1 Step 2).
    @ViewBuilder
    private var sourceAttributionRow: some View {
        if let attribution = recipe.sourceAttribution {
            Link(destination: attribution.url) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .accessibilityHidden(true)
                    Text("Source")
                        .font(.system(size: 16, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.sageAccent)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Open original recipe source")
        }
    }

    // MARK: Cook time + servings (one row)

    /// One quiet, boxless row: cook time on the left, the serving-size stepper on
    /// the right (space-between). When the recipe isn't scalable, the right side
    /// shows a static serving count instead of the stepper, so that info isn't
    /// lost. Text is value (bold) + label (secondary), no icon. Hidden entirely
    /// when neither side has anything to show.
    @ViewBuilder
    private var cookAndServingsRow: some View {
        let hasRight = recipe.canScaleServings || recipe.servings.displayString != nil
        if recipe.cookTimeMinutes != nil || hasRight {
            HStack(alignment: .center) {
                if let cook = recipe.cookTimeMinutes {
                    labeledValue(cook.minutesString, "Cook")
                }
                Spacer(minLength: 0)
                if recipe.canScaleServings {
                    servingAdjuster
                } else if let servings = recipe.servings.displayString {
                    labeledValue(servings, "Servings")
                }
            }
        }
    }

    /// A "value (bold) + label (secondary)" inline pair — the quiet meta style
    /// shared by the cook-time and static-servings cells.
    private func labeledValue(_ value: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
        }
    }

    // MARK: Nutrition

    /// Nutrition card, shown right below the meta row so its relationship to
    /// servings is obvious. Three states, driven entirely by what the server
    /// sent (never by the locally cached entitlement — see RecipeDetailView
    /// 1.1 Step 0): nutrition present → the full ring card; nutrition absent
    /// but `nutrition_locked` → the locked upsell card, same size; neither →
    /// hidden entirely (no empty/zero state).
    @ViewBuilder
    private var nutritionSection: some View {
        if let nutrition = recipe.nutrition {
            nutritionCard(nutrition)
        } else if recipe.isNutritionLocked {
            lockedNutritionCard
        }
    }

    private func nutritionCardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(20)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.nutritionCardBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func nutritionCardHeader(caption: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Nutrition")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Spacer(minLength: 8)
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(Color.nutritionCaption)
        }
    }

    /// One legend row: color dot, label, grams, calorie-share percent. `nil`
    /// grams/percent render as "—" — the locked card's state, sharing this
    /// exact layout with the unlocked card per spec.
    private func nutritionLegendRow(color: Color, label: String, grams: Int?, percent: Int?) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(grams.map { "\($0)g" } ?? "—")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text(percent.map { "\($0)%" } ?? "—")
                .font(.system(size: 13))
                .foregroundStyle(Color.nutritionCaption)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func nutritionCard(_ nutrition: Nutrition) -> some View {
        let display = nutrition.perServingDisplay(originalServings: recipe.baseServings)
        let share = nutrition.calorieShare
        let caption = "\(display.captionPrefix) · \(nutrition.sourceCaption)"

        return nutritionCardContainer {
            VStack(alignment: .leading, spacing: 16) {
                nutritionCardHeader(caption: caption)
                HStack(spacing: 22) {
                    NutritionRingView(nutrition: nutrition, displayCalories: display.calories)
                    VStack(alignment: .leading, spacing: 10) {
                        nutritionLegendRow(color: .sageAccent, label: "Protein", grams: display.proteinG, percent: share?.proteinPercent)
                        nutritionLegendRow(color: .nutritionCarbs, label: "Carbs", grams: display.carbsG, percent: share?.carbsPercent)
                        nutritionLegendRow(color: .nutritionFat, label: "Fat", grams: display.fatG, percent: share?.fatPercent)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nutritionAccessibilityLabel(display))
    }

    /// One combined label, e.g. "373 calories per serving: 24 grams protein,
    /// 37 grams carbs, 12 grams fat."
    private func nutritionAccessibilityLabel(_ display: Nutrition.PerServingResult) -> String {
        var macroParts: [String] = []
        if let p = display.proteinG { macroParts.append("\(p) grams protein") }
        if let c = display.carbsG { macroParts.append("\(c) grams carbs") }
        if let f = display.fatG { macroParts.append("\(f) grams fat") }
        let basis = display.captionPrefix.lowercased()

        guard let calories = display.calories else {
            return macroParts.isEmpty ? "Nutrition unavailable." : "Nutrition \(basis): \(macroParts.joined(separator: ", "))."
        }
        guard !macroParts.isEmpty else {
            return "\(calories) calories \(basis)."
        }
        return "\(calories) calories \(basis): \(macroParts.joined(separator: ", "))."
    }

    /// Free-account state: same size and layout as the data card, but the ring
    /// is a plain track + lock glyph and every legend value reads "—". Tapping
    /// anywhere opens the existing paywall.
    private var lockedNutritionCard: some View {
        Button {
            showPaywall = true
        } label: {
            nutritionCardContainer {
                VStack(alignment: .leading, spacing: 16) {
                    nutritionCardHeader(caption: "Per serving")
                    HStack(spacing: 22) {
                        LockedNutritionRingView()
                        VStack(alignment: .leading, spacing: 10) {
                            nutritionLegendRow(color: .sageAccent, label: "Protein", grams: nil, percent: nil)
                            nutritionLegendRow(color: .nutritionCarbs, label: "Carbs", grams: nil, percent: nil)
                            nutritionLegendRow(color: .nutritionFat, label: "Fat", grams: nil, percent: nil)
                        }
                    }
                    Text("Unlock with Pro")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.sageAccent)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Nutrition is a Pro feature. Double tap to unlock.")
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
                        IngredientText(
                            ingredient: ingredient,
                            scaledBy: recipe.canScaleServings ? scaler.ratio : nil
                        )
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
        RecipeDetailView(recipe: .spicyNoodles, cookbooks: CookbooksModel())
    }
    .environmentObject(SubscriptionService())
}

#Preview("Generated, no image") {
    NavigationStack {
        RecipeDetailView(recipe: .margheritaPizza, cookbooks: CookbooksModel())
    }
    .environmentObject(SubscriptionService())
}
