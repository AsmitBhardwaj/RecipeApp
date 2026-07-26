//
//  IdentityLogicTests.swift
//  RecipeKitTests
//
//  Host-safe tests of the identity resolve ALGORITHM against an in-memory store.
//  These run under `swift test` on macOS and do not need the iOS app-group
//  entitlement (which a real Keychain access group requires — that path is
//  verified separately on the simulator via RecipeKitDiagnostics).
//

import XCTest
@testable import RecipeKit

/// In-memory `SecretStore` that mimics Keychain semantics: `addIfAbsent` only
/// writes when the key is empty, so it exercises the race-convergence path.
final class InMemoryStore: SecretStore {
    private var storage: [String: String] = [:]
    private(set) var addCallCount = 0

    func string(forKey account: String) throws -> String? {
        storage[account]
    }

    func addIfAbsent(_ value: String, forKey account: String) throws -> Bool {
        addCallCount += 1
        if storage[account] != nil { return false }
        storage[account] = value
        return true
    }

    // Test hook: simulate another process having written first.
    func seed(_ value: String, forKey account: String) {
        storage[account] = value
    }
}

final class IdentityLogicTests: XCTestCase {
    private let account = "anonymous_user_id"

    func testGeneratesAndPersistsOnFirstCall() throws {
        let store = InMemoryStore()
        let id = Identity.resolveUserID(in: store, account: account)
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(try store.string(forKey: account), id, "the generated id must be persisted")
        XCTAssertNotNil(UUID(uuidString: id), "id should be a UUID string")
    }

    func testSecondCallReturnsSameID() throws {
        let store = InMemoryStore()
        let first = Identity.resolveUserID(in: store, account: account)
        let second = Identity.resolveUserID(in: store, account: account)
        XCTAssertEqual(first, second, "second launch/call must return the same id, not a new one")
        XCTAssertEqual(store.addCallCount, 1, "should only ever add once")
    }

    func testAdoptsExistingIDFromAnotherWriter() {
        let store = InMemoryStore()
        store.seed("PRE-EXISTING-ID", forKey: account)
        let id = Identity.resolveUserID(in: store, account: account)
        XCTAssertEqual(id, "PRE-EXISTING-ID", "must return the value another caller already stored")
        XCTAssertEqual(store.addCallCount, 0, "must not attempt to add when one already exists")
    }
}
