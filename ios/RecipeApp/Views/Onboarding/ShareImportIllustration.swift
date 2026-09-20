//
//  ShareImportIllustration.swift
//  RecipeApp
//
//  Vector (SwiftUI-drawn) illustration for onboarding screen 2 ("Share to
//  import"): a social post card with its Share button, above a share sheet whose
//  Platter icon is highlighted among generic app icons. Theme-aware via the
//  app's color tokens; no bitmap assets. Marked decorative for VoiceOver — the
//  screen's headline/body carry the meaning.
//

import SwiftUI

/// The app's brand mark, drawn in-code (there is no standalone logo asset — only
/// the `AppIcon` set, which isn't referenceable as an `Image`). A sage rounded
/// square with a cream fork/knife glyph; reused as the screen-4 "app icon".
struct PlatterMark: View {
    var size: CGFloat = 64
    var highlighted: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "fork.knife")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Color.secondaryAccent, lineWidth: 3)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: size * 0.06, y: size * 0.03)
    }
}

struct ShareImportIllustration: View {
    var body: some View {
        VStack(spacing: 18) {
            postCard
            shareSheet
        }
        .frame(maxWidth: 320)
        .accessibilityHidden(true)   // decorative; headline/body carry meaning
    }

    // A social post: thumbnail strip + a highlighted Share control.
    private var postCard: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.borderWarm)
                .frame(height: 92)
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.secondaryAccent.opacity(0.7))
                }
            HStack(spacing: 16) {
                Image(systemName: "heart")
                Image(systemName: "bubble.right")
                // The Share control, called out in sage.
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(Color.accentColor)
                    .font(.body.weight(.bold))
                    .padding(6)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                Spacer()
            }
            .font(.body)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .tornEdgeCard(padding: 0, bordered: false)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.cardEdge, lineWidth: 1))
    }

    // A share sheet: a row of generic app icons with Platter highlighted + labeled.
    private var shareSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(Color.textSecondary.opacity(0.3)).frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 18) {
                appTarget(mark: AnyView(PlatterMark(size: 52, highlighted: true)), label: "Platter", strong: true)
                appTarget(mark: AnyView(genericIcon("message.fill")), label: "Messages")
                appTarget(mark: AnyView(genericIcon("envelope.fill")), label: "Mail")
                appTarget(mark: AnyView(genericIcon("ellipsis")), label: "More")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.cardEdge, lineWidth: 1))
    }

    private func appTarget(mark: AnyView, label: String, strong: Bool = false) -> some View {
        VStack(spacing: 6) {
            mark.frame(width: 52, height: 52)
            Text(label)
                .font(.caption2.weight(strong ? .semibold : .regular))
                .foregroundStyle(strong ? Color.textPrimary : Color.textSecondary)
                .lineLimit(1)
        }
    }

    private func genericIcon(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.textSecondary.opacity(0.15))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.textSecondary)
            }
    }
}

#Preview {
    ShareImportIllustration().padding().appBackground()
}
