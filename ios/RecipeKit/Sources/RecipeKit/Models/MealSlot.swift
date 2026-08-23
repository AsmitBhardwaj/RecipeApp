//
//  MealSlot.swift
//  RecipeKit
//
//  The four named meal slots a recipe can be planned into on a given day. The
//  `allCases` order IS the display order (Breakfast → Lunch → Snacks → Dinner).
//
//  A day can hold multiple entries per slot (e.g. two snacks). Legacy meal-plan
//  entries saved before slots existed default to `.dinner` on decode — see
//  `MealPlanEntry`.
//

import Foundation

public enum MealSlot: String, Codable, CaseIterable, Hashable, Identifiable {
    case breakfast
    case lunch
    case snacks
    case dinner

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .snacks: return "Snacks"
        case .dinner: return "Dinner"
        }
    }
}
