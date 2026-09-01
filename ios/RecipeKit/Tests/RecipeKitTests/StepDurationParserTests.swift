//
//  StepDurationParserTests.swift
//  RecipeKitTests
//
//  Cook Mode Stage 1: the client-side duration fallback, the structured-wins
//  resolver, and Instruction's backward-compatible decoding of duration_seconds.
//

import XCTest
@testable import RecipeKit

final class StepDurationParserTests: XCTestCase {

    private func parse(_ s: String) -> Int? { StepDurationParser.seconds(from: s) }

    // MARK: - Core phrasings

    func testSingleUnitPhrasings() {
        XCTAssertEqual(parse("Bake for 20 minutes"), 1200)
        XCTAssertEqual(parse("let rest 10 mins"), 600)
        XCTAssertEqual(parse("Simmer 1 hour"), 3600)
        XCTAssertEqual(parse("cook for 45 seconds"), 45)
        XCTAssertEqual(parse("rest 30 sec"), 30)
        XCTAssertEqual(parse("bake 1 hr"), 3600)
    }

    func testAttachedAbbreviations() {
        XCTAssertEqual(parse("microwave 90s"), 90)
        XCTAssertEqual(parse("knead 20m"), 1200)
    }

    func testDecimalHours() {
        XCTAssertEqual(parse("bake 1.5 hours"), 5400)
    }

    // MARK: - Ranges -> lower bound

    func testRangesTakeLowerBound() {
        XCTAssertEqual(parse("2–3 min"), 120)     // en dash
        XCTAssertEqual(parse("2-3 min"), 120)     // hyphen
        XCTAssertEqual(parse("bake 25-30 minutes"), 1500)
        XCTAssertEqual(parse("rest 2 to 3 minutes"), 120)
    }

    // MARK: - Compound descending units summed

    func testCompoundHourMinute() {
        XCTAssertEqual(parse("cook for 1 hour 30 minutes"), 5400)
        XCTAssertEqual(parse("cook 1 hr 30 min"), 5400)
        XCTAssertEqual(parse("simmer 1 hour and 15 minutes"), 4500)
        XCTAssertEqual(parse("2 minutes 30 seconds"), 150)
    }

    func testNonDescendingSecondPhraseNotSummed() {
        // Second unit is not smaller than the first -> separate phrase, first wins.
        XCTAssertEqual(parse("30 minutes 1 hour"), 1800)
    }

    // MARK: - First match only

    func testFirstMatchOnlyOnMultipleDurations() {
        XCTAssertEqual(parse("chop for 5 min, then rest 10 min"), 300)
    }

    func testFirstTimeUnitWinsOverEarlierNonTimeNumbers() {
        XCTAssertEqual(parse("Preheat oven to 350°F, then bake for 5 minutes"), 300)
        XCTAssertEqual(parse("Bake at 400 for 25 minutes"), 1500)
    }

    // MARK: - Non-durations never match

    func testNoDurationReturnsNil() {
        XCTAssertNil(parse("Season with salt and pepper"))
        XCTAssertNil(parse("Preheat oven to 350°F"))
        XCTAssertNil(parse("Use a 9x13 baking dish"))
        XCTAssertNil(parse("Add 2 cups of flour"))
        XCTAssertNil(parse(""))
    }

    // MARK: - Resolver: structured wins, regex is the net

    func testEffectiveDurationPrefersStructuredField() {
        let structured = Instruction(stepNumber: 1, text: "bake for 20 minutes", durationSeconds: 999)
        XCTAssertEqual(structured.effectiveDurationSeconds, 999)   // backend value, not regex 1200
    }

    func testEffectiveDurationFallsBackToRegex() {
        let regexOnly = Instruction(stepNumber: 1, text: "bake for 20 minutes")
        XCTAssertEqual(regexOnly.effectiveDurationSeconds, 1200)
    }

    func testEffectiveDurationNilWhenNeither() {
        let none = Instruction(stepNumber: 1, text: "Season to taste")
        XCTAssertNil(none.effectiveDurationSeconds)
    }

    // MARK: - Instruction Codable back-compat

    func testLegacyJSONWithoutFieldDecodesToNil() throws {
        let json = #"{"step_number":1,"text":"old step"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Instruction.self, from: json)
        XCTAssertEqual(decoded.stepNumber, 1)
        XCTAssertNil(decoded.durationSeconds)
    }

    func testNewJSONDecodesDurationSeconds() throws {
        let json = #"{"step_number":2,"text":"bake","duration_seconds":1200}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Instruction.self, from: json)
        XCTAssertEqual(decoded.durationSeconds, 1200)
    }

    func testEncodeRoundTripsDurationSeconds() throws {
        let original = Instruction(stepNumber: 3, text: "rest", durationSeconds: 600)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(Instruction.self, from: data)
        XCTAssertEqual(back, original)
    }
}
