//
//  OnboardingView.swift
//  RecipeApp
//
//  A short, swipeable intro to the app: capture a recipe (Reel/TikTok/link),
//  plan the week, auto-build the grocery list, and organize with cookbooks.
//  Keeps the swipe + page-dot + Next/Skip mechanics; illustrations are vector,
//  SwiftUI-drawn, and adapt to light/dark via the app's color tokens
//  (see OnboardingIllustrations).
//

import SwiftUI

struct OnboardingView: View {
    /// Called when the user finishes the flow.
    let onFinish: () -> Void

    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            art: .plate,
            title: "turn any reel into a recipe",
            message: "ingredients, steps, and photos — done for you"
        ),
        OnboardingPage(
            art: .share,
            title: "share from instagram or tiktok",
            message: "tap share, choose recipeapp, done"
        ),
        OnboardingPage(
            art: .link,
            title: "or paste a link",
            message: "no video to share? tap + and drop in any recipe blog URL — we'll read that too."
        ),
        OnboardingPage(
            art: .week,
            title: "plan your week",
            message: "drag recipes into any day"
        ),
        OnboardingPage(
            art: .grocery,
            title: "a grocery list that fills itself",
            message: "everything from your meal plan, gathered into one checklist"
        ),
        OnboardingPage(
            art: .cookbooks,
            title: "organize with cookbooks",
            message: "group saved recipes into collections — weeknight, baking, whatever you like"
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            pageDots
                .padding(.bottom, 24)

            Button(action: advance) {
                Text(isLastPage ? "Get started" : "Next")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)

            Button("Skip", action: onFinish)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .opacity(isLastPage ? 0 : 1)
                .disabled(isLastPage)
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
    }

    /// Sage for the active dot, muted `cardEdge` outline for inactive.
    private var pageDots: some View {
        HStack(spacing: 9) {
            ForEach(0..<pages.count, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.accentColor : Color.clear)
                    .overlay(Circle().strokeBorder(Color.cardEdge, lineWidth: 1.5))
                    .frame(width: 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: page)
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
    let art: OnboardingArt
    let title: String
    let message: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            page.art.view
                .frame(height: 200)
            VStack(spacing: 14) {
                Text(page.title)
                    .font(.editorialTitle(size: 30, relativeTo: .largeTitle))
                    .multilineTextAlignment(.center)
                Text(page.message)
                    .font(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
