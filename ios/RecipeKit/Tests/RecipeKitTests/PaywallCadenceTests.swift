//
//  PaywallCadenceTests.swift
//  RecipeKitTests
//
//  Rules for the periodic app-open paywall: 3-day per-account frequency cap,
//  Pro users never shown, share/import launches skipped, in-progress states
//  skipped, and only after the server entitlement has resolved.
//

import XCTest
@testable import RecipeKit

final class PaywallCadenceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A free, signed-in user, freshly launched, with everything permitting the
    /// prompt. Individual tests flip one input to prove it blocks.
    private func decide(
        serverEntitlementResolved: Bool = true,
        isPro: Bool = false,
        lastShown: Date? = nil,
        onboardingPaywallShownThisSession: Bool = false,
        launchedFromShareOrImport: Bool = false,
        importInProgress: Bool = false,
        purchaseInProgress: Bool = false,
        anotherSheetPresented: Bool = false
    ) -> Bool {
        PaywallCadence.shouldPresentOnAppOpen(
            serverEntitlementResolved: serverEntitlementResolved,
            isPro: isPro,
            lastShown: lastShown,
            now: now,
            onboardingPaywallShownThisSession: onboardingPaywallShownThisSession,
            launchedFromShareOrImport: launchedFromShareOrImport,
            importInProgress: importInProgress,
            purchaseInProgress: purchaseInProgress,
            anotherSheetPresented: anotherSheetPresented
        )
    }

    func testShowsForFreeUserOnFirstOpen() {
        XCTAssertTrue(decide())
    }

    func testProUserNeverShown() {
        XCTAssertFalse(decide(isPro: true))
        // Even if it would otherwise be due, Pro is never shown.
        XCTAssertFalse(decide(isPro: true, lastShown: now.addingTimeInterval(-10 * 24 * 3600)))
    }

    func testNotShownUntilServerEntitlementResolves() {
        // No flash for Pro: don't decide before the server answer is in.
        XCTAssertFalse(decide(serverEntitlementResolved: false))
    }

    func testFrequencyCapWithinThreeDays() {
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3600)
        XCTAssertFalse(decide(lastShown: twoDaysAgo))
    }

    func testShownAgainAfterThreeDays() {
        let fourDaysAgo = now.addingTimeInterval(-4 * 24 * 3600)
        XCTAssertTrue(decide(lastShown: fourDaysAgo))
    }

    func testExactlyThreeDaysStillCapped() {
        let threeDays = now.addingTimeInterval(-3 * 24 * 3600 + 1)  // 1s short of 3 days
        XCTAssertFalse(decide(lastShown: threeDays))
    }

    func testNotSameSessionAsOnboardingPaywall() {
        XCTAssertFalse(decide(onboardingPaywallShownThisSession: true))
    }

    func testSkippedOnShareOrImportLaunch() {
        XCTAssertFalse(decide(launchedFromShareOrImport: true))
    }

    func testSkippedWhileImportInProgress() {
        XCTAssertFalse(decide(importInProgress: true))
    }

    func testSkippedWhilePurchaseInProgress() {
        XCTAssertFalse(decide(purchaseInProgress: true))
    }

    func testSkippedOnTopOfAnotherSheet() {
        XCTAssertFalse(decide(anotherSheetPresented: true))
    }
}

final class PaywallPresentationStoreTests: XCTestCase {

    private func makeStore() -> (PaywallPresentationStore, UserDefaults) {
        let suite = "paywall.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PaywallPresentationStore(defaults: defaults), defaults)
    }

    func testUnsetAccountHasNoTimestamp() {
        let (store, _) = makeStore()
        XCTAssertNil(store.lastShown(accountId: "acct-A"))
        XCTAssertNil(store.lastShown(accountId: nil))
    }

    func testRecordAndReadPerAccount() {
        let (store, _) = makeStore()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        store.recordShown(accountId: "acct-A", at: t)
        let read = store.lastShown(accountId: "acct-A")
        XCTAssertNotNil(read)
        XCTAssertEqual(read!.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 1)
        // Different account is independent.
        XCTAssertNil(store.lastShown(accountId: "acct-B"))
    }

    func testEndToEndCapAcrossTwoOpens() {
        let (store, _) = makeStore()
        let acct = "acct-A"
        let firstOpen = Date(timeIntervalSince1970: 1_800_000_000)

        // First open: nothing recorded → allowed; record it.
        XCTAssertTrue(PaywallCadence.shouldPresentOnAppOpen(
            serverEntitlementResolved: true, isPro: false,
            lastShown: store.lastShown(accountId: acct), now: firstOpen,
            onboardingPaywallShownThisSession: false, launchedFromShareOrImport: false,
            importInProgress: false, purchaseInProgress: false, anotherSheetPresented: false
        ))
        store.recordShown(accountId: acct, at: firstOpen)

        // Next open a day later: capped.
        let nextDay = firstOpen.addingTimeInterval(24 * 3600)
        XCTAssertFalse(PaywallCadence.shouldPresentOnAppOpen(
            serverEntitlementResolved: true, isPro: false,
            lastShown: store.lastShown(accountId: acct), now: nextDay,
            onboardingPaywallShownThisSession: false, launchedFromShareOrImport: false,
            importInProgress: false, purchaseInProgress: false, anotherSheetPresented: false
        ))

        // Four days later: allowed again.
        let later = firstOpen.addingTimeInterval(4 * 24 * 3600)
        XCTAssertTrue(PaywallCadence.shouldPresentOnAppOpen(
            serverEntitlementResolved: true, isPro: false,
            lastShown: store.lastShown(accountId: acct), now: later,
            onboardingPaywallShownThisSession: false, launchedFromShareOrImport: false,
            importInProgress: false, purchaseInProgress: false, anotherSheetPresented: false
        ))
    }
}
