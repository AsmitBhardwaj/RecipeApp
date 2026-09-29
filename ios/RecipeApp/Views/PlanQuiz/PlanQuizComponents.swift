//
//  PlanQuizComponents.swift
//  RecipeApp
//
//  Shared layout for the Plan on a Budget quiz: back button (44pt light-gray
//  circle) + sage progress bar, a 32pt DM Serif question, a gray subtitle, the
//  screen's content, and a Continue button pinned to the bottom (disabled until
//  the screen is valid). Also the selectable rows / tiles the screens share.
//
//  Visual tokens: sage primary buttons (56pt tall, 18pt radius); selected state
//  solid sage #56704F with white text (mood cards: 2.5pt sage border + check badge); secondary text #6B645B; 44pt minimum
//  touch targets; a VoiceOver label on everything.
//

import RecipeKit
import SwiftUI
import UIKit

enum QuizStyle {
    static let buttonHeight: CGFloat = 56
    static let buttonRadius: CGFloat = 18
    static let rowRadius: CGFloat = 16
    static let selectedBorder: CGFloat = 2
    static let selectedFill = Color(hex: "EEF3EC")
    static let backCircle = Color(hex: "F1EFE9")
    static let secondaryText = Color(hex: "6B645B")
    /// Selected rows / tiles: solid sage with white text (5.5:1 contrast).
    static let sage = Color(hex: "56704F")
    static let selectionAnimation = Animation.easeInOut(duration: 0.15)
}

// MARK: - Screen scaffold

struct QuizScreen<Content: View>: View {
    let title: String
    let subtitle: String
    let progress: Double
    let stepLabel: String
    let continueTitle: String
    let canContinue: Bool
    var continueHint: String = ""
    let onBack: () -> Void
    var showsBack = true
    let onContinue: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.editorialTitle(size: 32, relativeTo: .largeTitle))
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(QuizStyle.secondaryText)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                    content()
                        .padding(.top, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            bottomBar
        }
        .background(Color.appBackground.ignoresSafeArea())
        .foregroundStyle(Color.textPrimary)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            if showsBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(QuizStyle.backCircle, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            QuizProgressBar(fraction: progress)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stepLabel)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var bottomBar: some View {
        Button(action: onContinue) {
            Text(continueTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: QuizStyle.buttonHeight)
                .background(
                    Color.accentColor.opacity(canContinue ? 1 : 0.38),
                    in: RoundedRectangle(cornerRadius: QuizStyle.buttonRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canContinue)
        .accessibilityLabel(continueTitle)
        .accessibilityHint(canContinue ? continueHint : "Answer this question to continue")
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color.appBackground)
    }
}

struct QuizProgressBar: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hairline)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(8, proxy.size.width * min(max(fraction, 0), 1)))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: fraction)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Selection rows

/// A full-width list row with a round radio mark (single-select) or a square
/// checkbox (multi-select). Selected = #EEF3EC fill + 2pt sage border.
struct QuizOptionRow: View {
    enum Mark { case radio, checkbox }

    let title: String
    let isSelected: Bool
    let mark: Mark
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                markView
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 56)
            .modifier(QuizSelectionSurface(isSelected: isSelected, radius: QuizStyle.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    @ViewBuilder private var markView: some View {
        switch mark {
        case .radio:
            ZStack {
                Circle().strokeBorder(isSelected ? Color.white : Color.textSecondary.opacity(0.5), lineWidth: 2)
                if isSelected { Circle().fill(Color.white).padding(5) }
            }
            .frame(width: 24, height: 24)
        case .checkbox:
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white : Color.clear)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.white : Color.textSecondary.opacity(0.5), lineWidth: 2)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(QuizStyle.sage)
                }
            }
            .frame(width: 24, height: 24)
        }
    }
}

/// Selected: solid sage fill (#56704F). Unselected: surface + hairline. The fill
/// animates over 0.15s.
struct QuizSelectionSurface: ViewModifier {
    let isSelected: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(Color.surface)
                    shape.fill(QuizStyle.sage).opacity(isSelected ? 1 : 0)
                }
            }
            .overlay { shape.strokeBorder(Color.hairline, lineWidth: 1).opacity(isSelected ? 0 : 1) }
            .animation(QuizStyle.selectionAnimation, value: isSelected)
    }
}

// MARK: - Assets

/// A named asset that fills its frame, or — when the art hasn't landed yet — a
/// tinted rounded square (same fallback as Stage 1's `SoftAssetImage`).
struct QuizAssetImage: View {
    let name: String
    var cornerRadius: CGFloat = 14

    static func exists(_ name: String) -> Bool { UIImage(named: name) != nil }

    var body: some View {
        if Self.exists(name) {
            Image(name)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(QuizStyle.selectedFill)
        }
    }
}
