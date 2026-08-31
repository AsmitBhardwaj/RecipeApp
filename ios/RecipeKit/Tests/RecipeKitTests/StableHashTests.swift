//
//  StableHashTests.swift
//  RecipeKitTests
//
//  Guards the deterministic fallback-image selection: the same recipe id must
//  always map to the same bucket (unlike Swift's per-process-seeded Hasher), and
//  the "no image" badge must read honestly.
//

import XCTest
@testable import RecipeKit

final class StableHashTests: XCTestCase {

    func testStableIndexIsDeterministic() {
        let seed = "recipe-abc-123"
        let first = stableIndex(for: seed, modulo: 5)
        // Repeated calls must agree (the whole point — no per-run randomness).
        for _ in 0..<100 {
            XCTAssertEqual(stableIndex(for: seed, modulo: 5), first)
        }
    }

    func testStableIndexHasKnownFixedValues() {
        // Pin exact outputs so a future change to the hash (which would reshuffle
        // every recipe's image) fails loudly rather than silently.
        XCTAssertEqual(stableIndex(for: "recipe-abc-123", modulo: 5), 2)
        XCTAssertEqual(stableIndex(for: "", modulo: 5), 3)
    }

    func testStableIndexAlwaysInRange() {
        for i in 0..<500 {
            let idx = stableIndex(for: "id-\(i)", modulo: 5)
            XCTAssertTrue((0..<5).contains(idx), "index \(idx) out of range for id-\(i)")
        }
    }

    func testStableIndexDistributesAcrossBuckets() {
        // Not all ids should collide into one bucket — sanity that the fallback
        // images actually vary across recipes.
        var seen = Set<Int>()
        for i in 0..<200 { seen.insert(stableIndex(for: "recipe-\(i)", modulo: 5)) }
        XCTAssertEqual(seen.count, 5, "expected all 5 buckets to be hit")
    }

    func testNoImageBadgeLabelIsHonest() {
        XCTAssertEqual(ImageSource.none.badgeLabel, "No photo available")
    }
}
