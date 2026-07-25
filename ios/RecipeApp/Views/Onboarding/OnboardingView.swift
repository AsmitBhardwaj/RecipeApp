//
//  OnboardingView.swift
//  RecipeApp
//
//  A short, swipeable intro to the core loop: share a Reel/TikTok → get a
//  clean recipe back. First-pass copy and design, not final.
//

import SwiftUI

struct OnboardingView: View {
    /// Called when the user finishes the flow.
    let onFinish: () -> Void

    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            symbol: "square.and.arrow.up",
            title: "Save recipes from anywhere",
            message: "Found a recipe on Instagram or TikTok? Tap Share and send the video straight to RecipeApp."
        ),
        OnboardingPage(
            symbol: "wand.and.stars",
            title: "We do the reading for you",
            message: "We pull the recipe out of the caption and tidy it into clear ingredients and steps — no more scrubbing through a video."
        ),
        OnboardingPage(
            symbol: "book.closed",
            title: "Your own recipe box",
            message: "Every recipe you save lands in your list, ready to cook whenever you are."
        ),
    ]

    var body: some View {
        VStack {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(action: advance) {
                Text(isLastPage ? "Get started" : "Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Button("Skip", action: onFinish)
                .font(.subheadline)
                .padding(.bottom, 8)
                .opacity(isLastPage ? 0 : 1)
                .disabled(isLastPage)
        }
    }

    private var isLastPage: Bool { page == pages.count - 1 }

    private func advance() {
        if isLastPage {
            onFinish()
        } else {
            withAnimation { page += 1 }
        }
    }
}

// MARK: - Page model & single-page view

private struct OnboardingPage {
    let symbol: String
    let title: String
    let message: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: page.symbol)
                .font(.system(size: 84, weight: .thin))
                .foregroundStyle(.tint)
                .frame(height: 120)
            VStack(spacing: 14) {
                Text(page.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(page.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
