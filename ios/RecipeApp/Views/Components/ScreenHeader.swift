//
//  ScreenHeader.swift
//  RecipeApp
//
//  The shared screen header: a large, left-aligned serif title with optional
//  trailing action buttons — replacing the old centered inline navigation title.
//  Screens using it hide the navigation bar's title and render this at the top of
//  their content instead.
//
//  `CircleHeaderButton` is the standard 44pt circular header affordance:
//  a hairline-bordered surface for secondary actions, a sage fill for the
//  primary one. Both come straight from the design tokens.
//

import SwiftUI

/// Large left-aligned serif screen title + trailing buttons.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Text(title)
                .font(.editorialTitle(size: 34, relativeTo: .largeTitle))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: Theme.Spacing.sm)

            trailing()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.md)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title, trailing: { EmptyView() })
    }
}

/// A 44pt circular header button. `primary` fills it sage (white glyph);
/// otherwise it's a hairline-bordered surface circle (primary text glyph).
struct CircleHeaderButton: View {
    let systemImage: String
    var primary: Bool = false
    /// When true the button is non-interactive and dimmed (mirrors a toolbar
    /// button's `.disabled` treatment).
    var disabled: Bool = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(primary ? Color.white : Color.textPrimary)
                .frame(width: 44, height: 44)
                .background {
                    if primary {
                        Circle().fill(Color.accentColor)
                    } else {
                        Circle()
                            .fill(Color.surface)
                            .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview {
    VStack(spacing: 24) {
        ScreenHeader("Recipes") {
            CircleHeaderButton(systemImage: "person.crop.circle", accessibilityLabel: "Account") {}
            CircleHeaderButton(systemImage: "plus", primary: true, accessibilityLabel: "Add") {}
        }
        ScreenHeader("Meal Plan")
    }
    .appBackground()
}
