import XCTest
@testable import RecipeKit

final class ProEntitlementStateTests: XCTestCase {
    private let ids: Set<String> = ["monthly", "yearly"]
    private let now = Date(timeIntervalSince1970: 1_000)

    func testVerifiedCurrentSubscriptionGrantsAccess() {
        let record = SubscriptionEntitlementRecord(
            productID: "monthly",
            isVerified: true,
            expirationDate: now.addingTimeInterval(100)
        )

        let state = ProEntitlementEvaluator.evaluate(
            current: [record], latest: [record], productIDs: ids, now: now
        )

        XCTAssertEqual(state, .active(productID: "monthly", expirationDate: record.expirationDate))
        XCTAssertTrue(state.grantsAccess)
    }

    func testExpiredSubscriptionDoesNotGrantAccess() {
        let expiration = now.addingTimeInterval(-1)
        let record = SubscriptionEntitlementRecord(
            productID: "yearly",
            isVerified: true,
            expirationDate: expiration
        )

        let state = ProEntitlementEvaluator.evaluate(
            current: [], latest: [record], productIDs: ids, now: now
        )

        XCTAssertEqual(state, .expired(expirationDate: expiration))
        XCTAssertFalse(state.grantsAccess)
    }

    func testRevokedSubscriptionDoesNotGrantAccess() {
        let revocation = now.addingTimeInterval(-10)
        let record = SubscriptionEntitlementRecord(
            productID: "monthly",
            isVerified: true,
            expirationDate: now.addingTimeInterval(100),
            revocationDate: revocation
        )

        let state = ProEntitlementEvaluator.evaluate(
            current: [], latest: [record], productIDs: ids, now: now
        )

        XCTAssertEqual(state, .revoked(revocationDate: revocation))
        XCTAssertFalse(state.grantsAccess)
    }

    func testUnverifiedTransactionNeverGrantsAccess() {
        let record = SubscriptionEntitlementRecord(
            productID: "monthly",
            isVerified: false,
            expirationDate: now.addingTimeInterval(100)
        )

        let state = ProEntitlementEvaluator.evaluate(
            current: [record], latest: [record], productIDs: ids, now: now
        )

        XCTAssertEqual(state, .unverified)
        XCTAssertFalse(state.grantsAccess)
    }

    func testUnknownProductsAreIgnored() {
        let record = SubscriptionEntitlementRecord(
            productID: "some.other.product",
            isVerified: true,
            expirationDate: now.addingTimeInterval(100)
        )

        XCTAssertEqual(
            ProEntitlementEvaluator.evaluate(
                current: [record], latest: [record], productIDs: ids, now: now
            ),
            .notSubscribed
        )
    }
}
