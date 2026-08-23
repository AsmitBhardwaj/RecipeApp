//
//  GroceryShareTextTests.swift
//  RecipeKitTests
//
//  Pins the shared-list plain-text format: header, category grouping in
//  allCases order, skipped-empty categories, and per-item lines.
//

import XCTest
@testable import RecipeKit

final class GroceryShareTextTests: XCTestCase {

    private func item(_ name: String, qty: Double? = nil, unit: String? = nil, category: GroceryCategory) -> GroceryLineItem {
        GroceryLineItem(name: name, quantity: qty, unit: unit, category: category, sources: [])
    }

    /// 2026-08-23 is a Sunday.
    private var sunday: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 23; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testFormatGroupsByCategoryAndSkipsEmpty() {
        let items = [
            item("onions", qty: 2, category: .produce),
            item("garlic", category: .produce),
            item("rice", qty: 1, unit: "cup", category: .pantry),
        ]
        let text = GroceryShareText.build(items: items, for: sunday, locale: Locale(identifier: "en_US_POSIX"))

        XCTAssertEqual(text, """
        Platter — Grocery List for Sunday, Aug 23

        Produce
        - garlic
        - 2 onions

        Pantry
        - 1 cup rice
        """)
    }

    func testEmptyItemsIsHeaderOnly() {
        let text = GroceryShareText.build(items: [], for: sunday, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(text, "Platter — Grocery List for Sunday, Aug 23")
    }

    func testHandAddedItemsAppearUnderAddedByYouAfterCategories() {
        let items = [item("onions", qty: 2, category: .produce)]
        let text = GroceryShareText.build(
            items: items,
            for: sunday,
            manualItems: ["paper towels", "trash bags"],
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(text, """
        Platter — Grocery List for Sunday, Aug 23

        Produce
        - 2 onions

        Added by you
        - paper towels
        - trash bags
        """)
        // Ordering: the manual section comes after the recipe category.
        XCTAssertLessThan(text.range(of: "Produce")!.lowerBound,
                          text.range(of: "Added by you")!.lowerBound)
    }

    func testAddedByYouSectionOmittedWhenNoManualItems() {
        let items = [item("onions", qty: 2, category: .produce)]
        let text = GroceryShareText.build(items: items, for: sunday, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertFalse(text.contains("Added by you"))
    }

    func testManualOnlyStillProducesAShareableList() {
        // No recipe-derived items — only hand-added. The list must still render the
        // "Added by you" section (mirrors the view enabling the share button when
        // only hand-added items exist).
        let text = GroceryShareText.build(
            items: [],
            for: sunday,
            manualItems: ["napkins"],
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(text, """
        Platter — Grocery List for Sunday, Aug 23

        Added by you
        - napkins
        """)
    }

    func testCategoriesFollowAllCasesOrder() {
        // frozen is declared after pantry in allCases, so it must render after it.
        let items = [
            item("peas", category: .frozen),
            item("flour", category: .pantry),
        ]
        let text = GroceryShareText.build(items: items, for: sunday, locale: Locale(identifier: "en_US_POSIX"))
        let pantryIdx = text.range(of: "Pantry")!.lowerBound
        let frozenIdx = text.range(of: "Frozen")!.lowerBound
        XCTAssertLessThan(pantryIdx, frozenIdx)
    }
}
