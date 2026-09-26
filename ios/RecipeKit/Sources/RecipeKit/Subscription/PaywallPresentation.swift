import Foundation

public enum SubscriptionBillingUnit: String, Sendable {
    case day, week, month, year, period

    public var singular: String { rawValue }
    public var renewalAdverb: String {
        switch self {
        case .day: return "daily"
        case .week: return "weekly"
        case .month: return "monthly"
        case .year: return "annually"
        case .period: return "each billing period"
        }
    }
}

public struct IntroTrialPeriod: Equatable, Sendable {
    public let value: Int
    public let unit: SubscriptionBillingUnit

    public init(value: Int, unit: SubscriptionBillingUnit) {
        self.value = value
        self.unit = unit
    }

    public var freeText: String {
        let count = unit == .week ? value * 7 : value
        let noun = unit == .week ? "day" : unit.rawValue
        return "\(count) \(count == 1 ? noun : noun + "s") free"
    }

    public var statusText: String {
        let count = unit == .week ? value * 7 : value
        let noun = unit == .week ? "day" : unit.rawValue
        return "\(count)-\(noun) free trial"
    }
}

public struct PaywallPresentation: Equatable, Sendable {
    public let trialText: String?
    public let planSubtitle: String
    public let ctaTitle: String
    public let disclosure: String

    public static func make(
        localizedPrice: String,
        billingUnit: SubscriptionBillingUnit,
        freeTrial: IntroTrialPeriod?,
        isEligibleForIntroOffer: Bool
    ) -> Self {
        let billed = billingUnit == .year ? "Billed annually" : "Billed \(billingUnit.renewalAdverb)"
        let renewal = "Auto-renews \(billingUnit.renewalAdverb) until canceled."
        guard isEligibleForIntroOffer, let freeTrial else {
            return Self(
                trialText: nil,
                planSubtitle: billed,
                ctaTitle: "Continue with Pro",
                disclosure: "\(localizedPrice)/\(billingUnit.singular). \(renewal)"
            )
        }
        return Self(
            trialText: freeTrial.freeText,
            planSubtitle: freeTrial.statusText,
            ctaTitle: "Start Free Trial",
            disclosure: "\(freeTrial.freeText), then \(localizedPrice)/\(billingUnit.singular). \(renewal)"
        )
    }
}
