import XCTest
@testable import RecipeKit

final class PaywallPresentationTests: XCTestCase {
    private let week = IntroTrialPeriod(value: 1, unit: .week)

    func testEligibleYearlyFreeTrial() {
        let value = PaywallPresentation.make(
            localizedPrice: "29,99 €",
            billingUnit: .year,
            freeTrial: week,
            isEligibleForIntroOffer: true
        )
        XCTAssertEqual(value.trialText, "7 days free")
        XCTAssertEqual(value.planSubtitle, "7-day free trial")
        XCTAssertEqual(value.ctaTitle, "Start Free Trial")
        XCTAssertEqual(value.disclosure, "7 days free, then 29,99 €/year. Auto-renews annually until canceled.")
    }

    func testIneligibleOfferRemovesAllFreeLanguage() {
        let value = PaywallPresentation.make(
            localizedPrice: "$29.99",
            billingUnit: .year,
            freeTrial: week,
            isEligibleForIntroOffer: false
        )
        XCTAssertNil(value.trialText)
        XCTAssertFalse(value.planSubtitle.lowercased().contains("free"))
        XCTAssertFalse(value.ctaTitle.lowercased().contains("free"))
        XCTAssertFalse(value.disclosure.lowercased().contains("free"))
    }

    func testNoOfferRemovesTrialLanguage() {
        let value = PaywallPresentation.make(
            localizedPrice: "$29.99",
            billingUnit: .year,
            freeTrial: nil,
            isEligibleForIntroOffer: true
        )
        XCTAssertNil(value.trialText)
        XCTAssertEqual(value.disclosure, "$29.99/year. Auto-renews annually until canceled.")
    }

    func testMonthlyBillingPresentation() {
        let value = PaywallPresentation.make(
            localizedPrice: "$6.99",
            billingUnit: .month,
            freeTrial: nil,
            isEligibleForIntroOffer: false
        )
        XCTAssertEqual(value.planSubtitle, "Billed monthly")
        XCTAssertEqual(value.disclosure, "$6.99/month. Auto-renews monthly until canceled.")
    }

    func testYearlyBillingPresentation() {
        let value = PaywallPresentation.make(
            localizedPrice: "£24.99",
            billingUnit: .year,
            freeTrial: nil,
            isEligibleForIntroOffer: false
        )
        XCTAssertEqual(value.planSubtitle, "Billed annually")
        XCTAssertEqual(value.disclosure, "£24.99/year. Auto-renews annually until canceled.")
    }
}
