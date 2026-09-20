//
//  PaywallTests.swift
//  RecipeKitTests
//
//  Covers the paywall's pure logic: price/savings math, trigger→copy mapping,
//  trial-eligibility copy switching, and the mock scenarios.
//

import XCTest
@testable import RecipeKit

// MARK: - Helpers

private func makeOffering(
    annual: Decimal = 39.99,
    monthly: Decimal = 4.99,
    trialDays: Int? = 7,
    annualEligible: Bool = true,
    currency: String = "USD"
) -> PaywallOffering {
    PaywallOffering(
        annual: PaywallPlan(id: PaywallProductID.annual,
                            localizedPrice: PaywallPricing.formatted(annual, currencyCode: currency),
                            price: annual, currencyCode: currency, period: .annual,
                            introTrialDays: trialDays, isTrialEligible: annualEligible),
        monthly: PaywallPlan(id: PaywallProductID.monthly,
                             localizedPrice: PaywallPricing.formatted(monthly, currencyCode: currency),
                             price: monthly, currencyCode: currency, period: .monthly,
                             introTrialDays: nil, isTrialEligible: false)
    )
}

// MARK: - Pricing

final class PaywallPricingTests: XCTestCase {

    func testMonthlyEquivalentIsAnnualOverTwelve() {
        XCTAssertEqual(PaywallPricing.monthlyEquivalent(ofAnnual: 60), 5)
    }

    func testSavingsPercentComputedFromRealPrices() {
        // $39.99/yr vs $4.99/mo → 12×4.99 = 59.88; saving = 19.89/59.88 ≈ 33%.
        XCTAssertEqual(PaywallPricing.savingsPercent(annualPrice: 39.99, monthlyPrice: 4.99), 33)
    }

    func testSavingsHiddenWhenNoSaving() {
        // Annual not cheaper than 12× monthly → nil (pill hidden).
        XCTAssertNil(PaywallPricing.savingsPercent(annualPrice: 60, monthlyPrice: 4.99))
        XCTAssertNil(PaywallPricing.savingsPercent(annualPrice: 60, monthlyPrice: 5))   // exactly equal
    }

    func testSavingsHiddenWhenMonthlyZero() {
        XCTAssertNil(PaywallPricing.savingsPercent(annualPrice: 40, monthlyPrice: 0))
    }

    func testFormattedUsesCurrency() {
        XCTAssertTrue(PaywallPricing.formatted(39.99, currencyCode: "USD").contains("39.99"))
    }
}

// MARK: - Copy: trigger mapping

final class PaywallCopyTriggerTests: XCTestCase {

    func testHeadlinesPerTrigger() {
        XCTAssertEqual(PaywallCopy.headline(for: .importLimit), "Keep your cookbook growing.")
        XCTAssertEqual(PaywallCopy.headline(for: .settings), "Keep your cookbook growing.")
        XCTAssertEqual(PaywallCopy.headline(for: .pantry), "Cook with what you've got.")
    }

    func testImportLimitSubheadUsesLimitNotHardcoded() {
        XCTAssertTrue(PaywallCopy.subhead(for: .importLimit, freeImportLimit: 7).contains("7 free recipes"))
        XCTAssertTrue(PaywallCopy.subhead(for: .importLimit, freeImportLimit: 25).contains("25 free recipes"))
    }

    func testSettingsSubheadIsGenericWithNoCount() {
        let s = PaywallCopy.subhead(for: .settings, freeImportLimit: 10)
        XCTAssertEqual(s, "Get the most out of Platter.")
        XCTAssertFalse(s.contains("10"))
    }

    func testBenefitOrderLedByTrigger() {
        XCTAssertEqual(PaywallCopy.benefits(for: .importLimit).first, PaywallCopy.Benefit.unlimited)
        XCTAssertEqual(PaywallCopy.benefits(for: .settings).first, PaywallCopy.Benefit.unlimited)
        XCTAssertEqual(PaywallCopy.benefits(for: .pantry).first, PaywallCopy.Benefit.pantry)
        // Always the same three, always includes macros.
        for t in PaywallTrigger.allCases {
            XCTAssertEqual(Set(PaywallCopy.benefits(for: t)).count, 3)
            XCTAssertTrue(PaywallCopy.benefits(for: t).contains(PaywallCopy.Benefit.macros))
        }
    }
}

// MARK: - Copy: trial-eligibility switching

final class PaywallCopyEligibilityTests: XCTestCase {

    func testAnnualCTAAndFinePrintWhenTrialEligible() {
        let o = makeOffering(annualEligible: true)
        XCTAssertEqual(PaywallCopy.ctaTitle(selectedPeriod: .annual, offering: o), "Start 7-day free trial")
        XCTAssertTrue(PaywallCopy.finePrint(selectedPeriod: .annual, offering: o).hasPrefix("7 days free, then"))
        XCTAssertTrue(PaywallCopy.annualCardSubtitle(o).hasPrefix("7 days free, then"))
    }

    func testAnnualCTAAndFinePrintWhenNotTrialEligible() {
        let o = makeOffering(annualEligible: false)
        let cta = PaywallCopy.ctaTitle(selectedPeriod: .annual, offering: o)
        XCTAssertTrue(cta.hasPrefix("Subscribe for "))
        XCTAssertTrue(cta.hasSuffix("/year"))
        XCTAssertFalse(PaywallCopy.finePrint(selectedPeriod: .annual, offering: o).contains("free"))
        XCTAssertFalse(PaywallCopy.annualCardSubtitle(o).contains("free"))
    }

    func testMonthlyNeverShowsTrial() {
        let eligible = makeOffering(annualEligible: true)
        let cta = PaywallCopy.ctaTitle(selectedPeriod: .monthly, offering: eligible)
        XCTAssertTrue(cta.hasSuffix("/month"))
        XCTAssertFalse(cta.contains("free"))
        XCTAssertTrue(PaywallCopy.finePrint(selectedPeriod: .monthly, offering: eligible).contains("per month"))
    }
}

// MARK: - Mock scenarios

@MainActor
final class PaywallMockTests: XCTestCase {

    func testLoadFailureThrows() async {
        let mock = MockPaywallPurchasing(scenario: .loadFailure)
        do { _ = try await mock.loadOffering(); XCTFail("expected loadFailed") }
        catch { XCTAssertEqual(error as? PaywallError, .loadFailed) }
    }

    func testPurchaseOutcomes() async throws {
        let plan = try await MockPaywallPurchasing(scenario: .trialEligible).loadOffering().annual
        let cancelled = try await MockPaywallPurchasing(scenario: .purchaseCancelled).purchase(plan)
        XCTAssertEqual(cancelled, .cancelled)
        let ok = try await MockPaywallPurchasing(scenario: .trialEligible).purchase(plan)
        XCTAssertEqual(ok, .success)
        do { _ = try await MockPaywallPurchasing(scenario: .purchaseFails).purchase(plan); XCTFail() }
        catch { XCTAssertTrue(error is PaywallError) }
    }

    func testRestoreOutcomes() async throws {
        let nothing = try await MockPaywallPurchasing(scenario: .restoreNothing).restore()
        XCTAssertEqual(nothing, .nothingToRestore)
        let restored = try await MockPaywallPurchasing(scenario: .trialEligible).restore()
        XCTAssertEqual(restored, .restored)
    }

    func testNotTrialEligibleScenarioFlagsOffering() async throws {
        let o = try await MockPaywallPurchasing(scenario: .notTrialEligible).loadOffering()
        XCTAssertFalse(PaywallCopy.annualTrialEligible(o))
    }
}
