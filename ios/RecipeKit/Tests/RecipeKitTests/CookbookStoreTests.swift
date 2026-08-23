//
//  CookbookStoreTests.swift
//  RecipeKitTests
//
//  Covers cookbook persistence and the many-to-many membership mapping,
//  including the O(n) reverse lookup and the delete sweeps.
//

import XCTest
@testable import RecipeKit

final class CookbookStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "cookbook-tests-\(UUID().uuidString)")!
        return d
    }

    // MARK: - CookbookStore

    func testUpsertInsertsNewestFirstAndRenamesInPlace() {
        let store = CookbookStore(defaults: makeDefaults())
        let a = Cookbook(id: "a", name: "Weeknight")
        let b = Cookbook(id: "b", name: "Baking")
        store.upsert(a)
        store.upsert(b)
        XCTAssertEqual(store.all().map(\.id), ["b", "a"])  // newest first

        // Rename a in place — no new entry, order preserved.
        var renamed = a
        renamed.name = "Quick Dinners"
        store.upsert(renamed)
        XCTAssertEqual(store.all().map(\.id), ["b", "a"])
        XCTAssertEqual(store.all().first(where: { $0.id == "a" })?.name, "Quick Dinners")
    }

    func testRemove() {
        let store = CookbookStore(defaults: makeDefaults())
        store.upsert(Cookbook(id: "a", name: "A"))
        store.upsert(Cookbook(id: "b", name: "B"))
        store.remove(id: "a")
        XCTAssertEqual(store.all().map(\.id), ["b"])
    }

    // MARK: - Membership

    func testSetCookbooksAddsAndRemoves() {
        let m = CookbookMembershipStore(defaults: makeDefaults())
        m.setCookbooks(forRecipe: "r1", to: ["a", "b"])
        XCTAssertEqual(Set(m.recipeIds(inCookbook: "a")), ["r1"])
        XCTAssertEqual(Set(m.recipeIds(inCookbook: "b")), ["r1"])

        // Re-assign r1 to only b — it should leave a and stay in b.
        m.setCookbooks(forRecipe: "r1", to: ["b"])
        XCTAssertTrue(m.recipeIds(inCookbook: "a").isEmpty)
        XCTAssertEqual(Set(m.recipeIds(inCookbook: "b")), ["r1"])
    }

    func testManyToMany() {
        let m = CookbookMembershipStore(defaults: makeDefaults())
        m.setCookbooks(forRecipe: "r1", to: ["a", "b"])
        m.setCookbooks(forRecipe: "r2", to: ["a"])
        XCTAssertEqual(Set(m.recipeIds(inCookbook: "a")), ["r1", "r2"])
        XCTAssertEqual(Set(m.cookbookIds(forRecipe: "r1")), ["a", "b"])
        XCTAssertEqual(Set(m.cookbookIds(forRecipe: "r2")), ["a"])
    }

    func testRemoveCookbookDropsItsMembershipOnly() {
        let m = CookbookMembershipStore(defaults: makeDefaults())
        m.setCookbooks(forRecipe: "r1", to: ["a", "b"])
        m.removeCookbook("a")
        XCTAssertTrue(m.recipeIds(inCookbook: "a").isEmpty)
        XCTAssertEqual(Set(m.recipeIds(inCookbook: "b")), ["r1"])  // b untouched
    }

    func testRemoveRecipeSweepsAllCookbooks() {
        let m = CookbookMembershipStore(defaults: makeDefaults())
        m.setCookbooks(forRecipe: "r1", to: ["a", "b"])
        m.setCookbooks(forRecipe: "r2", to: ["a"])
        m.removeRecipe("r1")
        XCTAssertEqual(Set(m.recipeIds(inCookbook: "a")), ["r2"])
        XCTAssertTrue(m.recipeIds(inCookbook: "b").isEmpty)
        XCTAssertTrue(m.cookbookIds(forRecipe: "r1").isEmpty)
    }
}
