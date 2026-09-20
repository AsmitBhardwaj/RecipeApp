//
//  EmptyLibraryView.swift
//  RecipeApp
//
//  First-run empty state for the Recipes tab: shown when the account has no
//  saved recipes and nothing in flight. A food photo, the "start here"
//  headline/body, and a single inline "Share → Platter" hint (plus a paste
//  hint, since the + button accepts a pasted link).
//
//  The photo lives in the shared `EmptyStateDish` asset (moved out of the old
//  onboarding photography before that set was deleted) so it survives.
//

import SwiftUI

struct EmptyLibraryView: View {
    // Scales the inline hint with Dynamic Type (15pt at default) and the little
    // Platter mark alongside it.
    @ScaledMetric(relativeTo: .subheadline) private var hintSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var markSize: CGFloat = 24

    var body: some View {
        VStack(spacing: 20) {
            // Food photo: 300x280, ~28pt radius, aspect-fill, ~28pt under the title.
            Image("EmptyStateDish")
                .resizable()
                .scaledToFill()
                .frame(width: 300, height: 280)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.top, 28)
                .accessibilityHidden(true)

            Text("Your cookbook starts here.")
                .font(.editorialTitle(size: 32, relativeTo: .largeTitle))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 24)

            Text("Found a recipe on Instagram, TikTok or a blog? Share it to Platter and it lands here, ready to cook.")
                .font(.body)   // ~17pt, Dynamic Type
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)

            VStack(spacing: 6) {
                hintRow
                Text("or tap + to paste a link")
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 32)
    }

    // Inline hint: [􀈂] Share  ›  [P] Platter — one combined a11y label; wraps to
    // two rows at large Dynamic Type sizes via ViewThatFits.
    private var hintRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { shareChunk; chevron; platterChunk }
            VStack(spacing: 8) {
                HStack(spacing: 8) { shareChunk; chevron }
                platterChunk
            }
        }
        .font(.system(size: hintSize, weight: .semibold))
        .padding(.horizontal, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Share, then choose Platter")
    }

    private var shareChunk: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.arrow.up")
            Text("Share")
        }
        .foregroundStyle(Color.accentColor)
    }

    private var platterChunk: some View {
        HStack(spacing: 6) {
            platterMark
            Text("Platter")
        }
        .foregroundStyle(Color.accentColor)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: hintSize * 0.85, weight: .semibold))
            .foregroundStyle(Color.textSecondary.opacity(0.6))
    }

    // 24pt rounded-square Platter app-icon mark showing the "P".
    private var platterMark: some View {
        RoundedRectangle(cornerRadius: markSize * 0.28, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: markSize, height: markSize)
            .overlay {
                Text("P")
                    .font(.system(size: markSize * 0.62, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    EmptyLibraryView().appBackground()
}
