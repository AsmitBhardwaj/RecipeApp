//
//  GroceryItemIconTests.swift
//  RecipeKitTests
//
//  Pins the photo-vs-emoji resolver: real ingredients resolve to their bundled
//  photo key, the two split duplicate pairs land on distinct keys, compound
//  protein names map correctly, and qualified "no photo" forms fall through to
//  the emoji.
//

import XCTest
@testable import RecipeKit

final class GroceryItemIconTests: XCTestCase {

    private func key(_ name: String) -> String? { GroceryItemIconResolver.photoKey(for: name) }

    // MARK: Real items resolve to a photo key.

    func testCommonItemsGetPhotos() {
        XCTAssertEqual(key("yellow onion"), "onion")
        XCTAssertEqual(key("roma tomatoes"), "tomato")
        XCTAssertEqual(key("garlic cloves"), "garlic")
        XCTAssertEqual(key("fresh mozzarella"), "mozzarella")
        XCTAssertEqual(key("baby spinach"), "spinach")
        XCTAssertEqual(key("all-purpose flour"), "flour")
    }

    // MARK: Compound protein names map to the right cut.

    func testCompoundProteins() {
        XCTAssertEqual(key("boneless chicken thighs"), "chickenThigh")
        XCTAssertEqual(key("chicken breast"), "chickenBreast")
        XCTAssertEqual(key("diced chicken"), "chickenBreast")   // generic → breast
        XCTAssertEqual(key("ground beef"), "groundBeef")
        XCTAssertEqual(key("ribeye steak"), "beefSteak")
        XCTAssertEqual(key("beef sirloin"), "beefSteak")
        XCTAssertEqual(key("pork chops"), "porkChop")
        XCTAssertEqual(key("thick-cut bacon"), "bacon")
    }

    // MARK: The two split duplicate pairs cover distinct keys.

    func testDuplicatePairsAreSplit() {
        XCTAssertEqual(key("basmati rice"), "basmatiRice")
        XCTAssertEqual(key("jasmine rice"), "rice")
        XCTAssertEqual(key("white rice"), "rice")
        XCTAssertEqual(key("spaghetti"), "spaghetti")
        XCTAssertEqual(key("penne pasta"), "pasta")
    }

    // MARK: Cheese naming — generic "cheese" resolves to the shredded photo.

    func testCheeseKeys() {
        XCTAssertEqual(key("parmesan"), "parmesan")
        XCTAssertEqual(key("shredded cheese"), "shreddedCheese")
        XCTAssertEqual(key("cheddar cheese"), "shreddedCheese")
        XCTAssertEqual(key("cheese"), "shreddedCheese")
    }

    // MARK: "No photo" guards fall through to the emoji layer (key == nil).

    func testQualifiedFormsFallThrough() {
        XCTAssertNil(key("chicken broth"))       // not the chicken photo
        XCTAssertNil(key("garlic powder"))       // not the garlic photo
        XCTAssertNil(key("sweet potato"))        // not the potato photo
        XCTAssertNil(key("eggplant"))            // not the eggs photo
        XCTAssertNil(key("peanut butter"))       // not the butter photo
        XCTAssertNil(key("coconut milk"))        // not the milk photo
        XCTAssertNil(key("cream cheese"))        // not the cheese/cream photo
        XCTAssertNil(key("green onions"))        // not the onion photo
        XCTAssertNil(key("chili crisp"))         // not the green-chili photo
        XCTAssertNil(key("cornstarch"))          // not the corn photo
        XCTAssertNil(key("pineapple"))           // not the apple photo
        XCTAssertNil(key("olive oil"))
    }

    // MARK: The public icon() wraps key resolution + emoji fallback.

    func testIconWrapsPhotoOrEmoji() {
        XCTAssertEqual(GroceryItemIconResolver.icon(for: "yellow onion"), .photo("onion"))
        // Unmatched → emoji fallback (whatever GroceryItemEmoji gives).
        XCTAssertEqual(GroceryItemIconResolver.icon(for: "paper towels"), .emoji("🛒"))
        XCTAssertEqual(GroceryItemIconResolver.icon(for: "chicken broth"),
                       .emoji(GroceryItemEmoji.emoji(for: "chicken broth")))
    }
}
