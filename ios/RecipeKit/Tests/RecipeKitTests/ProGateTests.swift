//
//  ProGateTests.swift
//  RecipeKitTests
//
//  The Pro-gate decision (ProGate) and its per-account cached-entitlement source
//  (ProEntitlementCache). Pro follows the SERVER entitlement for the signed-in
//  account; device StoreKit is never an input to the gate.
//

import XCTest
@testable import RecipeKit

final class ProGateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProEntitlementCache.clear()
    }

    override func tearDown() {
        ProEntitlementCache.clear()
        super.tearDown()
    }

    // MARK: ProGate decision matrix (server-based)

    func testFreeAccountIsLocked() {
        XCTAssertFalse(ProGate.isUnlocked(serverIsPro: false, cached: false))
    }

    func testServerProIsUnlocked() {
        XCTAssertTrue(ProGate.isUnlocked(serverIsPro: true, cached: false))
    }

    func testCachedProUnlocksWithNoFlashOffline() {
        // Cold launch / offline: server not resolved yet, but the per-account cache
        // says Pro → unlocked immediately (no flash) for a returning subscriber.
        XCTAssertTrue(ProGate.isUnlocked(serverIsPro: false, cached: true))
    }

    func testNewAccountOnSubscribedDeviceShowsFree() {
        // The device's Apple ID may own a subscription, but that is NOT an input to
        // the gate. A brand-new account (server false, nothing cached) stays locked.
        XCTAssertFalse(ProGate.isUnlocked(serverIsPro: false, cached: false))
    }

    // MARK: needsRestore (paywall edge case)

    func testNeedsRestoreWhenDeviceHasEntitlementButAccountDoesNot() {
        XCTAssertTrue(ProGate.needsRestore(deviceHasEntitlement: true, serverIsPro: false))
    }

    func testNoRestorePromptWhenAccountAlreadyPro() {
        XCTAssertFalse(ProGate.needsRestore(deviceHasEntitlement: true, serverIsPro: true))
    }

    func testNoRestorePromptWhenDeviceHasNoEntitlement() {
        XCTAssertFalse(ProGate.needsRestore(deviceHasEntitlement: false, serverIsPro: false))
    }

    // MARK: ProEntitlementCache — per account

    func testCacheIsPerAccount() {
        // The Share Extension (and UI) read THIS account's cached server result;
        // one account's Pro must not read as another account's.
        ProEntitlementCache.set(true, accountId: "acct-A")
        XCTAssertTrue(ProEntitlementCache.isEntitled(accountId: "acct-A"))
        XCTAssertFalse(ProEntitlementCache.isEntitled(accountId: "acct-B"))
    }

    func testCacheRoundTrip() {
        ProEntitlementCache.set(true, accountId: "acct-A")
        XCTAssertTrue(ProEntitlementCache.isEntitled(accountId: "acct-A"))
        ProEntitlementCache.set(false, accountId: "acct-A")
        XCTAssertFalse(ProEntitlementCache.isEntitled(accountId: "acct-A"))
    }

    func testNilAccountIsNeverEntitled() {
        XCTAssertFalse(ProEntitlementCache.isEntitled(accountId: nil))
        XCTAssertFalse(ProEntitlementCache.isEntitled(accountId: ""))
    }

    func testSignOutClearsAllAccountsSoNextSignInStartsFree() {
        ProEntitlementCache.set(true, accountId: "acct-A")
        ProEntitlementCache.set(true, accountId: "acct-B")
        // resetForAccountChange() calls clear() on sign-out / delete.
        ProEntitlementCache.clear()
        XCTAssertFalse(ProEntitlementCache.isEntitled(accountId: "acct-A"))
        XCTAssertFalse(ProEntitlementCache.isEntitled(accountId: "acct-B"))
        // A different (new) account also starts free.
        XCTAssertFalse(ProEntitlementCache.isEntitled(accountId: "acct-C"))
    }
}
