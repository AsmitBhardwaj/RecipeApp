import RecipeKit
import SwiftUI

struct OnboardingScreen<Content: View>: View {
    let serifLine: String
    let scriptLine: String
    let bodyText: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: -3) {
                    Text(serifLine)
                        .font(.editorialTitle(size: 40, relativeTo: .largeTitle))
                    Text(scriptLine)
                        .font(.scriptAccent(size: 48, relativeTo: .largeTitle))
                        .foregroundStyle(Color.accentColor)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)

                Text(bodyText)
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                content().padding(.top, 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
    }
}

struct OnboardingPageDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.accentColor : Color.textSecondary.opacity(0.28))
                    .frame(width: index == current ? 20 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(total)")
    }
}

struct OnboardingPrimaryButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(.white)
                .background(Color.accentColor.opacity(isEnabled ? 1 : 0.38), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityHint(isEnabled ? "" : "Choose a primary cooking goal first")
    }
}

private struct OnboardingPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
    }
}

struct OnboardingValueScreen: View {
    private let recipes = [
        ("catPasta1", "Creamy tomato pasta"),
        ("catChicken1", "Lemon herb chicken"),
        ("catBreakfast1", "Spinach breakfast bowl")
    ]

    var body: some View {
        OnboardingScreen(
            serifLine: "Every recipe,",
            scriptLine: "one place.",
            bodyText: "Save recipes from Instagram, TikTok, and the web."
        ) {
            OnboardingPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Recipes").font(.headline)
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.textSecondary)
                    }
                    ForEach(recipes, id: \.1) { recipe in
                        HStack(spacing: 13) {
                            Image(recipe.0)
                                .resizable().scaledToFill()
                                .frame(width: 62, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .accessibilityHidden(true)
                            Text(recipe.1).font(.body.weight(.medium)).lineLimit(2)
                            Spacer()
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Example Platter recipe library with three saved recipes")
        }
    }
}

struct OnboardingSavingScreen: View {
    var body: some View {
        OnboardingScreen(
            serifLine: "Save it",
            scriptLine: "in two taps.",
            bodyText: "Tap Share, then choose Platter."
        ) {
            OnboardingPanel {
                HStack(spacing: 16) {
                    VStack(spacing: 9) {
                        Image("catPasta2")
                            .resizable().scaledToFill()
                            .frame(width: 92, height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(spacing: 9) {
                        PlatterMark(size: 92)
                        Text("Platter").font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Share a recipe, then choose Platter")
        }
    }
}

struct OnboardingGoalScreen: View {
    @Binding var selection: PrimaryCookingGoal?

    var body: some View {
        OnboardingScreen(
            serifLine: "What would make",
            scriptLine: "cooking easier?",
            bodyText: "Choose what you’d like Platter to help with most."
        ) {
            VStack(spacing: 12) {
                ForEach(PrimaryCookingGoal.allCases, id: \.self) { goal in
                    selectionRow(goal)
                }
            }
        }
    }

    private func selectionRow(_ goal: PrimaryCookingGoal) -> some View {
        let isSelected = selection == goal
        return Button { selection = goal } label: {
            HStack(spacing: 14) {
                Text(goal.displayName).font(.body.weight(.medium)).foregroundStyle(Color.textPrimary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(isSelected ? Color.sageLight.opacity(0.42) : Color.surface,
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : Color.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct OnboardingPreferencesScreen: View {
    @Binding var dietaryPreferences: Set<DietaryPreference>
    @Binding var householdSize: Int

    var body: some View {
        OnboardingScreen(
            serifLine: "Make it",
            scriptLine: "work for you.",
            bodyText: "Set a few defaults now. You can change them later in Account."
        ) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Anything you prefer or avoid?").font(.headline)
                    WrapLayout(spacing: 9, lineSpacing: 9) {
                        ForEach(DietaryPreference.allCases, id: \.self) { preference in
                            dietaryChip(preference)
                        }
                    }
                    Text("These choices guide recommendations and are not medical guarantees.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("How many people do you usually cook for?").font(.headline)
                    HStack(spacing: 24) {
                        stepperButton(systemImage: "minus", enabled: householdSize > 1) {
                            householdSize = max(1, householdSize - 1)
                        }
                        Text("\(householdSize)")
                            .font(.title2.weight(.semibold)).monospacedDigit().frame(minWidth: 34)
                            .accessibilityLabel("\(householdSize) people")
                        stepperButton(systemImage: "plus", enabled: householdSize < 12) {
                            householdSize = min(12, householdSize + 1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.hairline) }
                }
            }
        }
    }

    private func dietaryChip(_ preference: DietaryPreference) -> some View {
        let selected = dietaryPreferences.contains(preference)
        return Button {
            if preference == .noRestrictions {
                dietaryPreferences = selected ? [] : [.noRestrictions]
            } else {
                dietaryPreferences.remove(.noRestrictions)
                if selected { dietaryPreferences.remove(preference) }
                else { dietaryPreferences.insert(preference) }
            }
        } label: {
            HStack(spacing: 7) {
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                Text(preference.displayName)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 15)
            .frame(minHeight: 44)
            .background(selected ? Color.sageLight.opacity(0.42) : Color.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(selected ? Color.accentColor : Color.hairline) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stepperButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color.creamTint, in: Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(systemImage == "plus" ? "Increase household size" : "Decrease household size")
    }
}

struct OnboardingRegionScreen: View {
    @Binding var region: GroceryRegion?

    var body: some View {
        OnboardingScreen(
            serifLine: "Know your",
            scriptLine: "grocery costs.",
            bodyText: "Grocery prices vary a lot by where you shop. We use this to set realistic budgets when you plan a week of meals around a set amount."
        ) {
            VStack(spacing: 12) {
                ForEach(GroceryRegion.allCases, id: \.self) { option in
                    regionRow(option)
                }
            }
        }
    }

    private func regionRow(_ option: GroceryRegion) -> some View {
        let isSelected = region == option
        return Button { region = option } label: {
            HStack(spacing: 14) {
                Text(option.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(isSelected ? Color.sageLight.opacity(0.42) : Color.surface,
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : Color.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct OnboardingPantryScreen: View {
    static let staples = ["Eggs", "Spinach", "Rice", "Chicken", "Tomatoes", "Pasta"]

    @Binding var selections: Set<String>
    let suggestion: PantrySuggestion?
    let isLoading: Bool

    var body: some View {
        OnboardingScreen(
            serifLine: "Cook more",
            scriptLine: "with what you have.",
            bodyText: "Choose a few staples to find recipes that fit."
        ) {
            VStack(alignment: .leading, spacing: 24) {
                WrapLayout(spacing: 9, lineSpacing: 9) {
                    ForEach(Self.staples, id: \.self) { pantryChip($0) }
                }
                matchPanel
            }
        }
    }

    private func pantryChip(_ name: String) -> some View {
        let selected = selections.contains(name)
        return Button {
            if selected { selections.remove(name) } else { selections.insert(name) }
        } label: {
            HStack(spacing: 7) {
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                Text(name)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 15)
            .frame(minHeight: 44)
            .background(selected ? Color.sageLight.opacity(0.42) : Color.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(selected ? Color.accentColor : Color.hairline) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var matchPanel: some View {
        if let suggestion {
            OnboardingPanel {
                HStack(spacing: 14) {
                    RecipeImageView(imageUrl: suggestion.recipe.imageUrl,
                                    fallbackSeed: suggestion.recipe.recipeId,
                                    fallbackTitle: suggestion.recipe.title)
                        .frame(width: 72, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(suggestion.recipe.title).font(.headline).lineLimit(2)
                        Text("Uses \(suggestion.match.haveCount) of your items")
                            .font(.subheadline).foregroundStyle(Color.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .accessibilityElement(children: .combine)
        } else if isLoading {
            OnboardingPanel {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Finding a recipe match…").font(.subheadline).foregroundStyle(Color.textSecondary)
                    Spacer()
                }
            }
        } else {
            OnboardingPanel {
                HStack(spacing: 12) {
                    Image(systemName: selections.isEmpty ? "checklist" : "fork.knife")
                        .foregroundStyle(Color.accentColor)
                    Text(selections.isEmpty
                         ? "Select staples to see a recipe match."
                         : "No live match yet. Your pantry choices will still be saved.")
                        .font(.subheadline).foregroundStyle(Color.textSecondary)
                    Spacer()
                }
            }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : max(x - spacing, 0), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.width && x > 0 {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
