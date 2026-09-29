//
//  ImportHowTo.swift
//  RecipeApp
//
//  "Save recipes from anywhere": the first-open tip card on the Recipes tab and the
//  "How to import" sheet (empty state, + menu, "Show me how"). Both share one
//  SwiftUI-drawn `MiniPhone` illustration; no image assets besides the app icon.
//

import SwiftUI

private enum ImportHowToCopy {
    static let steps = [
        "Find a recipe on Instagram, TikTok or a blog",
        "Tap Share, then Platter",
        "It lands here, ready to cook",
    ]
    static let illustrationLabel = steps.enumerated()
        .map { "Step \($0.offset + 1): \($0.element)" }
        .joined(separator: ". ")
}

private enum HowToPalette {
    static let sage = Color(hex: "56704F")
    static let deepSage = Color(hex: "3E5238")
    static let cream = Color(hex: "F7F3EA")
    static let offWhite = Color(hex: "FBFAF7")
    static let tipBox = Color(hex: "F4EFE3")
    static let nearBlack = Color(hex: "1C1C1E")
    static let barGray = Color(hex: "D9D9DC")
    static let warmTop = Color(hex: "F2B978")
    static let warmBottom = Color(hex: "D9803F")
    static let gradient = LinearGradient(colors: [sage, deepSage], startPoint: .top, endPoint: .bottom)
}

// MARK: - MiniPhone

/// A tiny phone frame showing one step of the import flow. Drawn proportionally so
/// the same component renders at 84×136 (card) and 80×128 (sheet).
struct MiniPhone: View {
    enum Step { case post, share, landed }

    let step: Step
    var size = CGSize(width: 84, height: 136)

    private var border: CGFloat { 3 }
    private var inner: CGSize { CGSize(width: size.width - border * 2, height: size.height - border * 2) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(HowToPalette.nearBlack)
            screen
                .frame(width: inner.width, height: inner.height)
                .clipShape(RoundedRectangle(cornerRadius: 18 - border, style: .continuous))
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var screen: some View {
        switch step {
        case .post: postScreen
        case .share: shareScreen
        case .landed: landedScreen
        }
    }

    private var photo: some View {
        LinearGradient(colors: [HowToPalette.warmTop, HowToPalette.warmBottom], startPoint: .top, endPoint: .bottom)
            .overlay {
                Circle().fill(.white.opacity(0.35)).frame(width: inner.width * 0.5)
                Circle().fill(HowToPalette.warmBottom.opacity(0.55)).frame(width: inner.width * 0.3)
            }
    }

    private func bar(_ width: CGFloat, _ color: Color = HowToPalette.barGray, height: CGFloat = 5) -> some View {
        Capsule().fill(color).frame(width: inner.width * width, height: height)
    }

    // 1) A food post with a highlighted share button.
    private var postScreen: some View {
        VStack(spacing: 0) {
            photo.frame(height: inner.height * 0.62)
            VStack(alignment: .leading, spacing: 5) {
                bar(0.7)
                bar(0.45)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(HowToPalette.sage, in: Circle())
                .overlay(Circle().strokeBorder(HowToPalette.cream, lineWidth: 2))
                .background(Circle().fill(HowToPalette.cream.opacity(0.6)).frame(width: 32, height: 32))
                .padding(6)
        }
    }

    // 2) A share sheet with the Platter tile ringed.
    private var shareScreen: some View {
        ZStack(alignment: .bottom) {
            Color(hex: "E7E7EA")
            Color.black.opacity(0.35)
            VStack(spacing: 7) {
                Capsule().fill(HowToPalette.barGray).frame(width: 22, height: 3)
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(HowToPalette.barGray).frame(width: 14, height: 14)
                    }
                    VStack(spacing: 2) {
                        Image("PlatterIcon")
                            .resizable()
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .padding(2)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(HowToPalette.sage, lineWidth: 2))
                        Text("Platter")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(HowToPalette.deepSage)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 7)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(Color(hex: "F6F6F8"), in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
        }
    }

    // 3) The finished recipe.
    private var landedScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            photo
                .frame(height: inner.height * 0.4)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(HowToPalette.sage, in: Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .padding(5)
                }
            VStack(alignment: .leading, spacing: 5) {
                bar(0.75, HowToPalette.nearBlack.opacity(0.85), height: 6)
                bar(0.5)
                HStack(spacing: 4) {
                    chip("12 ingr.")
                    chip("8 steps")
                }
                bar(0.8, HowToPalette.barGray.opacity(0.5), height: 4)
                bar(0.6, HowToPalette.barGray.opacity(0.5), height: 4)
            }
            .padding(.horizontal, 7)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 6.5, weight: .semibold))
            .foregroundStyle(HowToPalette.deepSage)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(HowToPalette.sage.opacity(0.16), in: Capsule())
            .fixedSize()
    }
}

/// Dotted cream arrow linking two phones.
private struct DottedArrow: View {
    var color: Color = HowToPalette.cream

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 2, y: y))
            line.addLine(to: CGPoint(x: size.width - 5, y: y))
            context.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 5]))
            var head = Path()
            head.move(to: CGPoint(x: size.width - 8, y: y - 4))
            head.addLine(to: CGPoint(x: size.width - 3, y: y))
            head.addLine(to: CGPoint(x: size.width - 8, y: y + 4))
            context.stroke(head, with: .color(color),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(minWidth: 12, maxWidth: .infinity)
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

// MARK: - Tip card

/// Dismissible first-open card on the Recipes tab.
struct ImportTipCard: View {
    let onDismiss: () -> Void
    @State private var showingHowTo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            illustration
            HStack(spacing: 12) {
                cardButton("Show me how", filled: false) { showingHowTo = true }
                cardButton("Got it", filled: true, action: onDismiss)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HowToPalette.gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: HowToPalette.sage.opacity(0.28), radius: 14, y: 10)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showingHowTo) { ImportHowToSheet() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                // Cream on #56704F is 4.95:1 at full opacity but only ~4.4:1 at 90%,
                // so the eyebrow stays fully opaque.
                Text("NEW HERE?")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(HowToPalette.cream)
                Text("Save recipes\nfrom anywhere")
                    .font(.editorialTitle(size: 26, relativeTo: .title2))
                    .foregroundStyle(HowToPalette.cream)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HowToPalette.cream)
                    .frame(width: 32, height: 32)
                    .background(HowToPalette.cream.opacity(0.18), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -6)
            .padding(.trailing, -6)
            .accessibilityLabel("Dismiss")
        }
    }

    private var illustration: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                MiniPhone(step: .post)
                DottedArrow()
                MiniPhone(step: .share)
                DottedArrow()
                MiniPhone(step: .landed)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(ImportHowToCopy.steps.enumerated()), id: \.offset) { index, text in
                    Text("\(index + 1). \(text)")
                        .font(.system(size: 12))
                        .foregroundStyle(HowToPalette.cream)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ImportHowToCopy.illustrationLabel)
    }

    private func cardButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: filled ? .bold : .semibold))
                .foregroundStyle(filled ? HowToPalette.deepSage : HowToPalette.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background {
                    if filled {
                        shape.fill(HowToPalette.cream)
                    } else {
                        shape.strokeBorder(HowToPalette.cream.opacity(0.6), lineWidth: 1.5)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sheet

/// The "How to import" sheet.
struct ImportHowToSheet: View {
    @Environment(\.dismiss) private var dismiss

    private static let cards: [(MiniPhone.Step, String, String)] = [
        (.post, "Find a recipe you like", "On Instagram, TikTok, or any food blog."),
        (.share, "Tap Share, then Platter", "Platter shows up in the share row with the other apps."),
        (.landed, "It lands in Recipes", "Ingredients, steps and a photo, ready to cook."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                ForEach(Array(Self.cards.enumerated()), id: \.offset) { index, card in
                    stepCard(index: index, phone: card.0, title: card.1, detail: card.2)
                }
                tipBox
                Button { dismiss() } label: {
                    Text("Got it")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(HowToPalette.sage, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(20)
        }
        .background(HowToPalette.offWhite.ignoresSafeArea())
        .preferredColorScheme(.light)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image("PlatterIcon")
                .resizable()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            Text("How to import")
                .font(.editorialTitle(size: 28, relativeTo: .title))
                .foregroundStyle(HowToPalette.cream)
                .accessibilityAddTraits(.isHeader)
            // Full-opacity cream: 92% falls just under 4.5:1 against the lighter sage.
            Text("Any recipe, one tap, no copy-paste")
                .font(.system(size: 15))
                .foregroundStyle(HowToPalette.cream)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(HowToPalette.gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.top, 12)
    }

    private func stepCard(index: Int, phone: MiniPhone.Step, title: String, detail: String) -> some View {
        HStack(spacing: 16) {
            MiniPhone(step: phone, size: CGSize(width: 80, height: 128))
            VStack(alignment: .leading, spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(HowToPalette.deepSage)
                    .frame(width: 28, height: 28)
                    .background(HowToPalette.sage.opacity(0.16), in: Circle())
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color(hex: "1F2A1C"))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "5F6660"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1): \(title). \(detail)")
    }

    private var tipBox: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("?")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(HowToPalette.sage, in: Circle())
                .accessibilityHidden(true)
            Text("Can't see Platter? Scroll the app row to the end, tap More, and turn Platter on. You only do this once.")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "3B423A"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HowToPalette.tipBox, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The small "How to import" link used in empty states.
struct HowToImportLink: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("How to import", systemImage: "questionmark.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Card") {
    ImportTipCard {}.padding().appBackground()
}

#Preview("Sheet") {
    ImportHowToSheet()
}
