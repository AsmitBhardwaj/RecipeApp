//
//  GroceryItemEmojiTests.swift
//  RecipeKitTests
//
//  Pins the ingredient→emoji dictionary: each item resolves by its own name (not
//  by section), specific terms beat the generic word they contain, and unknowns
//  fall to the neutral cart.
//

import XCTest
@testable import RecipeKit

final class GroceryItemEmojiTests: XCTestCase {

    private func emoji(_ name: String) -> String { GroceryItemEmoji.emoji(for: name) }

    // MARK: The real 3-recipe in-app sample renders 16 distinct, correct icons.

    func testRealSeededSample() {
        XCTAssertEqual(emoji("spaghetti"), "🍝")
        XCTAssertEqual(emoji("unsalted butter"), "🧈")
        XCTAssertEqual(emoji("garlic cloves"), "🧄")
        XCTAssertEqual(emoji("chili crisp"), "🌶️")
        XCTAssertEqual(emoji("soy sauce"), "🫙")
        XCTAssertEqual(emoji("sugar"), "🍬")
        XCTAssertEqual(emoji("pizza dough ball"), "🍞")
        XCTAssertEqual(emoji("self-rising flour"), "🌾")
        XCTAssertEqual(emoji("green onions"), "🧅")
        XCTAssertEqual(emoji("toasted sesame seeds"), "🥜")
        XCTAssertEqual(emoji("crushed San Marzano tomatoes"), "🍅")
        XCTAssertEqual(emoji("fresh mozzarella"), "🧀")
        XCTAssertEqual(emoji("fresh basil leaves"), "🌿")
        XCTAssertEqual(emoji("olive oil"), "🫒")
        XCTAssertEqual(emoji("flaky salt"), "🧂")
        XCTAssertEqual(emoji("Greek yogurt"), "🥛")
    }

    // MARK: Items in the same section still get their OWN icon (the reported bug).

    func testProduceItemsAreIndividuated() {
        XCTAssertEqual(emoji("yellow onion"), "🧅")
        XCTAssertEqual(emoji("roma tomato"), "🍅")
        XCTAssertEqual(emoji("russet potato"), "🥔")
        XCTAssertEqual(emoji("lemon juice"), "🍋")
        XCTAssertEqual(emoji("bell pepper"), "🫑")
        XCTAssertEqual(emoji("baby carrots"), "🥕")
    }

    func testMeatItemsAreIndividuated() {
        XCTAssertEqual(emoji("chicken thighs"), "🍗")
        XCTAssertEqual(emoji("ground beef"), "🥩")
        XCTAssertEqual(emoji("thick-cut bacon"), "🥓")
        XCTAssertEqual(emoji("salmon fillet"), "🐟")
        XCTAssertEqual(emoji("jumbo shrimp"), "🦐")
    }

    func testDairyItemsAreIndividuated() {
        XCTAssertEqual(emoji("whole milk"), "🥛")
        XCTAssertEqual(emoji("salted butter"), "🧈")
        XCTAssertEqual(emoji("sharp cheddar cheese"), "🧀")
        XCTAssertEqual(emoji("large eggs"), "🥚")
    }

    // MARK: Specific terms beat the generic word they contain (ordering).

    func testSpecificBeatsGeneric() {
        XCTAssertEqual(emoji("garlic powder"), "🧂")   // not 🧄
        XCTAssertEqual(emoji("bell pepper"), "🫑")      // not 🧂 (black pepper)
        XCTAssertEqual(emoji("sweet potato"), "🍠")     // not 🥔
        XCTAssertEqual(emoji("eggplant"), "🍆")         // not 🥚
        XCTAssertEqual(emoji("peanut butter"), "🫙")    // not 🧈 / 🥜
        XCTAssertEqual(emoji("cream cheese"), "🧀")     // not 🥛
        XCTAssertEqual(emoji("coconut milk"), "🥥")     // not 🥛
        XCTAssertEqual(emoji("chicken broth"), "🥫")    // not 🍗
        XCTAssertEqual(emoji("cornstarch"), "🧂")       // not 🌽
    }

    // MARK: Spices/condiments → neutral shaker; unknowns → cart.

    func testSpicesAndUnknowns() {
        XCTAssertEqual(emoji("smoked paprika"), "🧂")
        XCTAssertEqual(emoji("ground turmeric"), "🧂")
        XCTAssertEqual(emoji("black pepper"), "🧂")
        XCTAssertEqual(emoji("paper towels"), "🛒")
        XCTAssertEqual(emoji("dish soap"), "🛒")
    }
}
