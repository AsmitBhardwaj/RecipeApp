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
