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

    func testClearRemovesEntitledClaim() {
        // A prior account left a Pro claim on this device.
        ProEntitlementCache.set(true)
        XCTAssertTrue(ProEntitlementCache.isEntitled)

        // `SubscriptionService.resetForAccountChange()` calls this on sign-out /
        // delete so the claim can't leak into the next account.
        ProEntitlementCache.clear()
        XCTAssertFalse(ProEntitlementCache.isEntitled)
    }

    // MARK: resetForAccountChange → refreshEntitlement restore path
    //
    // `SubscriptionService.resetForAccountChange()` clears the cache and then calls
    // `refreshEntitlement()`, which is: evaluate verified StoreKit records →
    // `ProEntitlementCache.set(state.grantsAccess)`. StoreKit itself needs the app
    // target + a StoreKit test host, but the clear→evaluate→re-cache chain that
    // decides whether Pro is restored is RecipeKit-pure and modeled here.

    private let productIDs: Set<String> = ["com.recipeapp.platterpro.yearly"]

    func testRefreshAfterClearRestoresProWhenAppleIDStillOwnsSubscription() {
        // Simulate the reset: cache is wiped first.
        ProEntitlementCache.set(true)
        ProEntitlementCache.clear()
        XCTAssertFalse(ProEntitlementCache.isEntitled)

        // The subsequent refresh finds a verified, unexpired, non-revoked
        // entitlement (the Apple ID genuinely still owns Pro).
        let active = SubscriptionEntitlementRecord(
            productID: "com.recipeapp.platterpro.yearly",
            isVerified: true,
            expirationDate: Date().addingTimeInterval(60 * 60 * 24 * 30),
            revocationDate: nil
        )
        let state = ProEntitlementEvaluator.evaluate(
            current: [active], latest: [active], productIDs: productIDs
        )
        ProEntitlementCache.set(state.grantsAccess)

        XCTAssertTrue(state.grantsAccess)              // live truth = Pro
        XCTAssertTrue(ProEntitlementCache.isEntitled)  // cache correctly restored
    }

    func testRefreshAfterClearLeavesFreeWhenAppleIDHasNoSubscription() {
        // Reset wipes a stale claim...
        ProEntitlementCache.set(true)
        ProEntitlementCache.clear()

        // ...and the refresh finds no entitlement (fresh account, Apple ID owns
        // nothing) → stays free, so the paywall (Bug 2) correctly appears.
        let state = ProEntitlementEvaluator.evaluate(
            current: [], latest: [], productIDs: productIDs
        )
        ProEntitlementCache.set(state.grantsAccess)

        XCTAssertFalse(state.grantsAccess)
        XCTAssertFalse(ProEntitlementCache.isEntitled)
    }
}
