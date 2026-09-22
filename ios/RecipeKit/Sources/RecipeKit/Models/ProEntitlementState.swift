//
//  ProEntitlementState.swift
//  RecipeKit
//
//  StoreKit-independent entitlement policy. The app converts verified StoreKit
//  transactions into these records; keeping the policy pure makes revocation,
//  expiration, and unverified-result handling unit testable.
//

import Foundation

public enum ProEntitlementState: Equatable, Sendable {
    case unknown
    case notSubscribed
    case active(productID: String, expirationDate: Date?)
    case expired(expirationDate: Date?)
    case revoked(revocationDate: Date)
    case unverified

    /// The only state that unlocks future Pro features. Cached UI state is never
    /// fed into this value.
    public var grantsAccess: Bool {
        if case .active = self { return true }
        return false
    }
}

public struct SubscriptionEntitlementRecord: Equatable, Sendable {
    public let productID: String
    public let isVerified: Bool
    public let expirationDate: Date?
    public let revocationDate: Date?

    public init(
        productID: String,
        isVerified: Bool,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil
    ) {
        self.productID = productID
        self.isVerified = isVerified
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
    }
}

public enum ProEntitlementEvaluator {
    public static func evaluate(
        current: [SubscriptionEntitlementRecord],
        latest: [SubscriptionEntitlementRecord],
        productIDs: Set<String>,
        now: Date = Date()
    ) -> ProEntitlementState {
        let relevantCurrent = current.filter { productIDs.contains($0.productID) }

        let active = relevantCurrent
            .filter {
                $0.isVerified
                    && $0.revocationDate == nil
                    && ($0.expirationDate == nil || $0.expirationDate! > now)
            }
            .max { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }

        if let active {
            return .active(productID: active.productID, expirationDate: active.expirationDate)
        }

        if relevantCurrent.contains(where: { !$0.isVerified }) {
            return .unverified
        }

        let relevantLatest = latest
            .filter { productIDs.contains($0.productID) }
            .sorted { ($0.expirationDate ?? .distantPast) > ($1.expirationDate ?? .distantPast) }

        if relevantLatest.contains(where: { !$0.isVerified }) {
            return .unverified
        }

        if let revoked = relevantLatest.first(where: { $0.revocationDate != nil }),
           let date = revoked.revocationDate {
            return .revoked(revocationDate: date)
        }

        if let expired = relevantLatest.first(where: {
            guard let expiration = $0.expirationDate else { return false }
            return expiration <= now
        }) {
            return .expired(expirationDate: expired.expirationDate)
        }

        return .notSubscribed
    }
}
