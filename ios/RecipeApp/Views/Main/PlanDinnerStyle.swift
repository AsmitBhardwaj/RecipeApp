//
//  PlanDinnerStyle.swift
//  RecipeApp
//
//  The dinner card's shared visual pieces: the category-tinted sticker tile, the
//  white shadowed card surface, the appliance SF Symbols, and the press style.
//  Used by "Your week" and by the paywall teaser's "Next week" preview so the two
//  always look alike.
//

import RecipeKit
import SwiftUI
import UIKit

extension FoodSticker {
    /// Tile tint for the sticker's food category.
    var tileTint: Color {
        switch self {
        case .pasta: return Color(hex: "F6E3D3")
        case .riceBowl: return Color(hex: "F4EBD0")
        case .noodles: return Color(hex: "F3E6CC")
        case .soup: return Color(hex: "F1E2D9")
        case .salad: return Color(hex: "E3EFDD")
        case .tacos: return Color(hex: "F6E6CF")
        case .curry: return Color(hex: "F5E0C8")
        case .chicken: return Color(hex: "F3E7D6")
        case .seafood: return Color(hex: "DDE8EE")
        case .generic: return Color(hex: "EEF3EC")
        }
    }
}

/// A rounded tile tinted by food category, with the sticker on top when the art
/// exists (until it lands, the tint alone shows).
/// A remote plan photo that fades in once loaded. Shows `placeholder` until then
/// and on failure. Uses AsyncImage, i.e. the app's existing URLCache-backed loading.
struct PlanPhoto<Placeholder: View>: View {
    let url: String
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        AsyncImage(url: URL(string: url), transaction: Transaction(animation: .easeIn(duration: 0.3))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill().transition(.opacity)
            default:
                placeholder()
            }
        }
    }
}

struct DinnerTile: View {
    let category: FoodSticker
    var size: CGFloat = 64
    /// Stock photo; when set (and loaded) it replaces the tinted tile + sticker.
    var photoURL: String? = nil

    var body: some View {
        if let photoURL, !photoURL.isEmpty {
            PlanPhoto(url: photoURL) { tile }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
        } else {
            tile
        }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(category.tileTint)
            .frame(width: size, height: size)
            .overlay {
                if UIImage(named: category.assetName) != nil {
                    Image(category.assetName)
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.1)
                }
            }
            .accessibilityHidden(true)
    }
}

/// White card, no border, soft shadow (y 4, blur 12, 6% black), 18pt radius.
struct DinnerCardSurface: ViewModifier {
    static let radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(Color.white, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func dinnerCardSurface() -> some View { modifier(DinnerCardSurface()) }
}

/// Pressed = scale 0.98.
struct DinnerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Bold price pill: sage text on #EEF3EC.
struct DinnerPricePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(QuizStyle.sage)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(Color(hex: "EEF3EC"), in: Capsule())
            .fixedSize()
    }
}

/// Clock + "35 min", then one small icon per appliance. Never wraps.
struct DinnerMetaRow: View {
    let timeLabel: String?
    let equipment: [String]

    var body: some View {
        HStack(spacing: 10) {
            if let timeLabel {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(timeLabel).lineLimit(1).fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(timeLabel)
            }
            ForEach(Array(DinnerEquipment.icons(for: equipment).prefix(5).enumerated()), id: \.offset) { _, item in
                Image(systemName: item.symbol)
                    .accessibilityLabel(item.label)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)
    }
}

enum DinnerEquipment {
    struct Icon { let symbol: String; let label: String }

    /// Closest SF Symbol per appliance; falls back to a flame if a symbol isn't
    /// available on the running OS.
    static func symbol(for raw: String) -> String {
        let name: String
        switch raw {
        case "stovetop": name = "flame"
        case "oven": name = "oven"
        case "microwave": name = "microwave"
        case "air_fryer": name = "wind"
        case "slow_cooker": name = "timer"
        case "rice_cooker": name = "drop"
        case "blender": name = "waveform"
        case "kettle": name = "mug"
        case BudgetEquipment.noCook: name = "fork.knife"
        default: name = "flame"
        }
        return UIImage(systemName: name) != nil ? name : "flame"
    }

    /// One icon per distinct appliance; a lone `no_cook` is "fork.knife", and
    /// `no_cook` beside real appliances is dropped (same rule as the labels).
    static func icons(for raw: [String]) -> [Icon] {
        var seen = Set<String>()
        let unique = raw.filter { seen.insert($0).inserted }
        let appliances = unique.filter { $0 != BudgetEquipment.noCook }
        let used = appliances.isEmpty ? (unique.isEmpty ? [] : [BudgetEquipment.noCook]) : appliances
        return used.map { Icon(symbol: symbol(for: $0), label: BudgetEquipment.label(for: $0)) }
    }
}
