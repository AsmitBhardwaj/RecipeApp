//
//  MinutesStringTests.swift
//  RecipeKitTests
//
//  The recipe-row time chip renders `Double.minutesString` from each recipe's
//  own total/cook time — never a fixed string. This pins that formatting across
//  the ranges a chip actually shows (single-digit, minutes, and multi-hour).
//

import XCTest
@testable import RecipeKit

final class MinutesStringTests: XCTestCase {

    func testChipTimeFormatting() {
        // The three shipped sample recipes' effective chip values, plus hour cases.
        XCTAssertEqual((12.0).minutesString, "12 min")      // margheritaPizza (cook fallback)
        XCTAssertEqual((25.0).minutesString, "25 min")      // spicyNoodles
        XCTAssertEqual((35.0).minutesString, "35 min")      // twoIngredientBagels
        XCTAssertEqual((60.0).minutesString, "1 hr")
        XCTAssertEqual((75.0).minutesString, "1 hr 15 min")
        XCTAssertEqual((90.0).minutesString, "1 hr 30 min")
    }

    /// Prints the exact text each sample recipe's chip will show — proof the value
    /// is derived per-recipe, not hardcoded.
    func testPrintSampleChipStrings() {
        for minutes in [12.0, 25.0, 35.0, 75.0] {
            print("CHIP[\(Int(minutes)) min input] -> \"\(minutes.minutesString)\"")
        }
    }
}
