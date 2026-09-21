//
//  ShareImportIllustration.swift
//  RecipeApp
//
//  Vector (SwiftUI-drawn) illustration for onboarding screen 2 ("Share to
//  import"): a recipe video block with its like/comment/share actions, above a
//  share sheet whose Platter tile is the highlighted target among generic app
//  tiles. Theme-aware via the app's adaptive color tokens; no bitmap assets.
//  Marked decorative for VoiceOver with one combined label — the headline/body
//  carry the meaning.
//

import SwiftUI

/// The app's brand mark: a sage rounded square holding the cream DM Serif "P"
/// from the app icon (no fork-and-knife glyph). Drawn in-code — the `AppIcon`
/// set isn't referenceable as an `Image`. Reused as the lockup tile, the share
/// sheet's Platter target, and the screen-4 hero tile. `cornerRadius` tracks
/// size (×0.25): 30 → ~8pt, 62 → ~15pt, 88 → 22pt.
struct PlatterMark: View {
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: size, height: size)
            .overlay {
                Text("P")
                    .font(.editorialTitle(size: size * 0.6))
                    .foregroundStyle(Color.markOnSage)
            }
    }
}

struct ShareImportIllustration: View {
    var body: some View {
        VStack(spacing: 20) {
            videoCard
            shareSheet
        }
        .frame(maxWidth: 320)
        // Decorative sample — its labels shouldn't grow with Dynamic Type.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement()
        .accessibilityLabel("Tap Share on a recipe post, then choose Platter.")
    }

    // A recipe video: play-button block + a like/comment/share action row.
    private var videoCard: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.videoBlockFill)
                .frame(height: 150)
                .overlay {
                    Circle()
                        .fill(Color.textPrimary)
                        .frame(width: 52, height: 52)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.videoBlockFill)
                        }
                }

            HStack(spacing: 18) {
                Image(systemName: "heart")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.dimLabel)
                Image(systemName: "bubble.right")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.dimLabel)
                Spacer(minLength: 0)
                shareButton
            }
        }
    }

    // The Share control, called out in sage with a "1" count badge.
    private var shareButton: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color.accentColor, in: Circle())
            .overlay(alignment: .topTrailing) {
                countBadge(1).offset(x: -6, y: -6)
            }
    }

    // A share sheet: a grabber above four evenly-spaced app tiles, Platter first.
    private var shareSheet: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(Color.inactiveDot)
                .frame(width: 36, height: 4)

            HStack(spacing: 0) {
                appTile(mark: AnyView(platterTile), label: "Platter", badge: 2, strong: true)
                appTile(mark: AnyView(neutralTile("message")), label: "Messages")
                appTile(mark: AnyView(neutralTile("envelope")), label: "Mail")
                appTile(mark: AnyView(neutralTile("ellipsis")), label: "More")
            }
        }
        .padding(16)
        .background(Color.surfacePanel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var platterTile: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 62, height: 62)
            .overlay {
                Text("P")
                    .font(.editorialTitle(size: 36))
                    .foregroundStyle(Color.markOnSage)
            }
    }

    private func neutralTile(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.neutralTile)
            .frame(width: 62, height: 62)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Color.neutralGlyph)
            }
    }

    private func appTile(mark: AnyView, label: String, badge: Int? = nil, strong: Bool = false) -> some View {
        VStack(spacing: 6) {
            mark
                .overlay(alignment: .topTrailing) {
                    if let badge { countBadge(badge).offset(x: -6, y: -6) }
                }
            Text(label)
                .font(.system(size: 12, weight: strong ? .semibold : .regular))
                .foregroundStyle(strong ? Color.textPrimary : Color.dimLabel)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func countBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.numberBadgeText)
            .frame(width: 20, height: 20)
            .background(Color.numberBadgeFill, in: Circle())
    }
}

#Preview {
    ShareImportIllustration().padding().appBackground()
}
