//
//  OnboardingIllustrations.swift
//  RecipeApp
//
//  Vector, SwiftUI-drawn illustrations for onboarding — no baked images. Each is
//  composed from `Shape`/`Path` + primitives stroked/filled with the app's color
//  tokens, so they adapt to light/dark automatically:
//    • line   = Color.textPrimary
//    • accent = Color.accentColor    (sage)
//    • accent = Color.secondaryAccent (clay)
//  Strictly three colors max, matching the app's illustration approach.
//

import SwiftUI

/// Selects an onboarding illustration. `@ViewBuilder` so each case can return its
/// own concrete view.
enum OnboardingArt {
    case plate, share, link, week, grocery, cookbooks

    @ViewBuilder var view: some View {
        switch self {
        case .plate: PlateArt()
        case .share: ShareArt()
        case .link: LinkArt()
        case .week: WeekArt()
        case .grocery: GroceryArt()
        case .cookbooks: CookbooksArt()
        }
    }
}

// MARK: - Shared stroke

private func lineStyle(_ width: CGFloat = 3) -> StrokeStyle {
    StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
}

// MARK: - 1. Plate with crossed utensils

private struct PlateArt: View {
    var body: some View {
        ZStack {
            ForkGlyph()
                .stroke(Color.accentColor, style: lineStyle())
                .frame(width: 46, height: 150)
                .rotationEffect(.degrees(-24))
            KnifeGlyph()
                .stroke(Color.secondaryAccent, style: lineStyle())
                .frame(width: 46, height: 150)
                .rotationEffect(.degrees(24))
            Circle().stroke(Color.textPrimary, lineWidth: 3).frame(width: 116, height: 116)
            Circle().stroke(Color.textPrimary, lineWidth: 2).frame(width: 86, height: 86)
        }
        .frame(width: 210, height: 180)
    }
}

private struct ForkGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let cx = r.midX
        p.move(to: CGPoint(x: cx, y: r.maxY))
        p.addLine(to: CGPoint(x: cx, y: r.midY))
        let base = r.midY, top = r.minY + r.height * 0.12
        let left = cx - r.width * 0.20, right = cx + r.width * 0.20
        p.move(to: CGPoint(x: left, y: base))
        p.addLine(to: CGPoint(x: right, y: base))
        for x in [left, cx, right] {
            p.move(to: CGPoint(x: x, y: base))
            p.addLine(to: CGPoint(x: x, y: top))
        }
        return p
    }
}

private struct KnifeGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let cx = r.midX
        p.move(to: CGPoint(x: cx, y: r.maxY))
        p.addLine(to: CGPoint(x: cx, y: r.midY))
        // slim blade from midY up to the top
        p.move(to: CGPoint(x: cx, y: r.midY))
        p.addLine(to: CGPoint(x: cx - r.width * 0.14, y: r.minY + r.height * 0.16))
        p.addQuadCurve(to: CGPoint(x: cx, y: r.minY),
                       control: CGPoint(x: cx - r.width * 0.14, y: r.minY + r.height * 0.02))
        p.addLine(to: CGPoint(x: cx, y: r.midY))
        return p
    }
}

// MARK: - 2. Phone with share motif

private struct ShareArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).stroke(Color.textPrimary, lineWidth: 3)
                .frame(width: 104, height: 170)
            Capsule().fill(Color.textPrimary).frame(width: 24, height: 4).offset(y: -73) // speaker
            UTray().stroke(Color.accentColor, style: lineStyle())
                .frame(width: 56, height: 42).offset(y: 22)
            ShareArrow().stroke(Color.accentColor, style: lineStyle())
                .frame(width: 30, height: 48).offset(y: -6)
            Capsule().fill(Color.secondaryAccent).frame(width: 40, height: 8).offset(y: 66) // clay bar
        }
        .frame(width: 160, height: 190)
    }
}

/// An open-topped tray (the "box" of the iOS share glyph).
private struct UTray: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// An upward arrow (shaft + head).
private struct ShareArrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let cx = r.midX
        p.move(to: CGPoint(x: cx, y: r.maxY))
        p.addLine(to: CGPoint(x: cx, y: r.minY))
        p.addLine(to: CGPoint(x: cx - r.width * 0.32, y: r.minY + r.height * 0.28))
        p.move(to: CGPoint(x: cx, y: r.minY))
        p.addLine(to: CGPoint(x: cx + r.width * 0.32, y: r.minY + r.height * 0.28))
        return p
    }
}

// MARK: - 3. Browser window, link, and +

private struct LinkArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).stroke(Color.textPrimary, lineWidth: 3)
                .frame(width: 168, height: 124)
            RoundedRectangle(cornerRadius: 5).stroke(Color.textPrimary, lineWidth: 2)
                .frame(width: 120, height: 18).offset(y: -34) // address bar
            ChainLink().offset(y: 12)
            ZStack {
                Circle().fill(Color.secondaryAccent).frame(width: 38, height: 38)
                PlusGlyph().stroke(.white, style: lineStyle()).frame(width: 15, height: 15)
            }
            .offset(x: 74, y: 52)
        }
        .frame(width: 210, height: 170)
    }
}

/// Two interlocking capsule rings — a chain "link".
private struct ChainLink: View {
    var body: some View {
        ZStack {
            Capsule().stroke(Color.accentColor, lineWidth: 3)
                .frame(width: 46, height: 22).rotationEffect(.degrees(-40)).offset(x: -11, y: 9)
            Capsule().stroke(Color.accentColor, lineWidth: 3)
                .frame(width: 46, height: 22).rotationEffect(.degrees(-40)).offset(x: 11, y: -9)
        }
        .frame(width: 76, height: 46)
    }
}

private struct PlusGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

// MARK: - 4. Seven-day week strip

private struct WeekArt: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { _ in
                    Capsule().fill(Color.textSecondary.opacity(0.5)).frame(width: 12, height: 3)
                }
            }
            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { i in
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.textPrimary, lineWidth: 2.5)
                            .frame(width: 22, height: 32)
                        if i == 1 { Circle().fill(Color.accentColor).frame(width: 11, height: 11) }
                        if i == 4 { Circle().fill(Color.secondaryAccent).frame(width: 11, height: 11) }
                    }
                }
            }
        }
        .frame(width: 230, height: 170)
    }
}

// MARK: - 5. Grocery list from the meal plan

private struct GroceryArt: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                CalendarBadge()
                DownArrow().stroke(Color.secondaryAccent, style: lineStyle())
                    .frame(width: 20, height: 26)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14).stroke(Color.textPrimary, lineWidth: 3)
                    .frame(width: 150, height: 132)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<4, id: \.self) { i in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4).stroke(Color.textPrimary, lineWidth: 2)
                                    .frame(width: 18, height: 18)
                                if i < 2 {
                                    Checkmark().stroke(Color.accentColor, style: lineStyle(2.5))
                                        .frame(width: 12, height: 12)
                                }
                            }
                            Capsule().fill(Color.textPrimary.opacity(0.4))
                                .frame(width: i % 2 == 0 ? 72 : 54, height: 5)
                        }
                    }
                }
                .frame(width: 150)
            }
        }
        .frame(width: 210, height: 190)
    }
}

private struct CalendarBadge: View {
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 4).stroke(Color.secondaryAccent, lineWidth: 2.5)
                .frame(width: 26, height: 24)
            Capsule().fill(Color.secondaryAccent).frame(width: 20, height: 4).offset(y: -3)
        }
        .frame(width: 30, height: 28)
    }
}

private struct Checkmark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.40, y: r.minY + r.height * 0.82))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.88, y: r.minY + r.height * 0.18))
        return p
    }
}

private struct DownArrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let cx = r.midX
        p.move(to: CGPoint(x: cx, y: r.minY))
        p.addLine(to: CGPoint(x: cx, y: r.maxY))
        p.addLine(to: CGPoint(x: cx - r.width * 0.38, y: r.maxY - r.height * 0.3))
        p.move(to: CGPoint(x: cx, y: r.maxY))
        p.addLine(to: CGPoint(x: cx + r.width * 0.38, y: r.maxY - r.height * 0.3))
        return p
    }
}

// MARK: - 6. Stacked cookbooks

private struct CookbooksArt: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            BookSpine(height: 96, filled: false, bookmark: false)
            BookSpine(height: 124, filled: false, bookmark: true)
            BookSpine(height: 106, filled: true, bookmark: false)
        }
        .frame(width: 210, height: 170)
    }
}

private struct BookSpine: View {
    let height: CGFloat
    let filled: Bool
    let bookmark: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(filled ? Color.accentColor.opacity(0.28) : Color.clear)
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.textPrimary, lineWidth: 3)
            // two title bands on the spine
            VStack(spacing: 8) {
                Capsule().fill(Color.textPrimary.opacity(0.4)).frame(height: 3)
                Capsule().fill(Color.textPrimary.opacity(0.4)).frame(height: 3)
            }
            .padding(.horizontal, 7)
            .padding(.top, 14)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 36, height: height)
        .overlay(alignment: .top) {
            if bookmark {
                BookmarkRibbon().fill(Color.secondaryAccent)
                    .frame(width: 14, height: 30).offset(y: -9)
            }
        }
    }
}

private struct BookmarkRibbon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.32))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
