//
//  ProGateTests.swift
//  RecipeKitTests
//
//  The Pro-gate decision (ProGate) and its cached-entitlement source
//  (ProEntitlementCache): free vs Pro vs loading.
//

import XCTest
@testable import RecipeKit

final class ProGateTests: XCTestCase {

    // MARK: ProGate decision matrix

    func testFreeUserIsLocked() {
        // No live grant, nothing cached → locked.
        XCTAssertFalse(ProGate.isUnlocked(live: false, cached: false))
    }

    func testProUserIsUnlocked() {
        // Verified live entitlement → unlocked.
        XCTAssertTrue(ProGate.isUnlocked(live: true, cached: false))
    }

    func testLoadingProUserIsUnlockedFromCacheWithNoFlash() {
        // Cold launch: live entitlement not resolved yet (false), but the App
        // Group cache says Pro → unlocked immediately, so no flash of a locked
        // state for a returning subscriber.
        XCTAssertTrue(ProGate.isUnlocked(live: false, cached: true))
    }

    func testInSessionPurchaseUnlocksEvenIfCacheStale() {
        // A purchase this session flips `live` true before the cache is rewritten.
        XCTAssertTrue(ProGate.isUnlocked(live: true, cached: true))
    }

    // MARK: ProEntitlementCache round-trip

    func testCacheRoundTrip() {
        ProEntitlementCache.set(true)
        XCTAssertTrue(ProEntitlementCache.isEntitled)
        ProEntitlementCache.set(false)
        XCTAssertFalse(ProEntitlementCache.isEntitled)
    }
}
