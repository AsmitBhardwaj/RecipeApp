//
//  RecipeImageCategoryTests.swift
//  RecipeKitTests
//
//  Pins the title→category matcher: dish-name overrides beat keywords, keyword
//  tokens resolve protein-forward, and non-food/unknown titles return nil (→
//  random bundled fallback).
//

import XCTest
@testable import RecipeKit

final class RecipeImageCategoryTests: XCTestCase {

    private func cat(_ title: String) -> RecipeImageCategory? {
        RecipeImageCategorizer.category(for: title)
    }

    // MARK: Tier 1 — overrides win over keywords

    func testOverridesBeatKeywords() {
        // "chicken noodle soup" contains chicken + noodle + soup keywords, but the
        // override maps the whole dish to soup.
        XCTAssertEqual(cat("Grandma's Chicken Noodle Soup"), .soup)
        // "chicken alfredo" → pasta despite the leading "chicken" keyword.
        XCTAssertEqual(cat("Creamy Chicken Alfredo"), .pasta)
        // "fried rice" → rice even though a protein word may precede it.
        XCTAssertEqual(cat("Easy Chicken Fried Rice"), .rice)
        // "beef stew" → soup, not beef.
        XCTAssertEqual(cat("Hearty Beef Stew"), .soup)
    }

    func testAmbiguousOverridesUseAgreedLeanings() {
        XCTAssertEqual(cat("Jollof Rice"), .rice)
        XCTAssertEqual(cat("Pad Thai"), .seafood)
        XCTAssertEqual(cat("Banana Bread"), .breakfastBaked)
    }

    // MARK: Tier 2 — keyword tokens, protein-forward

    func testKeywordMatching() {
        XCTAssertEqual(cat("Garlic Butter Salmon"), .fish)
        XCTAssertEqual(cat("Spicy Shrimp Tacos"), .seafood)
        XCTAssertEqual(cat("Classic Beef Burger"), .beef)
        XCTAssertEqual(cat("Cacio e Pepe Pasta"), .pasta)
        XCTAssertEqual(cat("Thai Green Curry"), .soup)
        XCTAssertEqual(cat("Fluffy Blueberry Pancakes"), .breakfastBaked)
        XCTAssertEqual(cat("Pho"), .beef)
        XCTAssertEqual(cat("Chocolate Lava Cake"), .dessert)
    }

    func testFirstMatchingTokenWins() {
        // "chicken" precedes "rice" → chicken (protein-forward); but the
        // "fried rice" override above takes precedence when present.
        XCTAssertEqual(cat("Chicken and Rice"), .chicken)
        // "salmon" precedes "salad" → fish.
        XCTAssertEqual(cat("Salmon Salad"), .fish)
    }

    // MARK: No match → nil

    func testUnknownTitleReturnsNil() {
        XCTAssertNil(cat("Grandma's Secret Surprise"))
        XCTAssertNil(cat(""))
        XCTAssertNil(cat("The Best Thing Ever"))
    }

    func testWordBoundaryAvoidsFalsePositivesWithinWords() {
        // "Fisherman's Wharf Platter" — "fish" is not a standalone token here
        // ("fisherman" is one token), so it should NOT match .fish.
        XCTAssertNotEqual(cat("Fisherman's Wharf Platter"), .fish)
    }
}
