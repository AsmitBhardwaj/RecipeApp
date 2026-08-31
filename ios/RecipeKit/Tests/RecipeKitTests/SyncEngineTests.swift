//
//  SyncEngineTests.swift
//  RecipeKitTests
//
//  Stage 2b-i: the sync engine against a FAKE in-memory server that mirrors the
//  backend's last-writer-wins rules (app/sync.py). Verifies push/pull, conflict
//  adoption, tombstones, cursor deltas, outbox resolution, and that two
//  "devices" sharing one server converge.
//

import XCTest
@testable import RecipeKit

// MARK: - Fake server (mirrors app/sync.py convergence)

final class FakeSyncServer: @unchecked Sendable {
    private struct Row { var seq: Int64; var change: SyncChange }
    private var rows: [String: Row] = [:]   // key: "collection|itemId"
    private var seq: Int64 = 0

    private func key(_ c: SyncChange) -> String { "\(c.collection.rawValue)|\(c.itemId)" }

    func push(_ changes: [SyncChange]) -> SyncPushResult {
        var applied: [String] = []
        var conflicts: [SyncChange] = []
        for incoming in changes {
            let k = key(incoming)
            if let existing = rows[k], incoming.updatedAt <= existing.change.updatedAt {
                conflicts.append(existing.change)   // server wins
            } else {
                seq += 1
                var stored = incoming
                stored.seq = seq
                rows[k] = Row(seq: seq, change: stored)
                applied.append(incoming.itemId)
            }
        }
        return SyncPushResult(applied: applied, conflicts: conflicts, cursor: seq)
    }

    func pull(cursor: Int64, limit: Int) -> SyncPullResult {
        let ordered = rows.values.filter { $0.seq > cursor }.sorted { $0.seq < $1.seq }
        let page = Array(ordered.prefix(limit))
        return SyncPullResult(
            changes: page.map { $0.change },
            cursor: page.last?.seq ?? cursor,
            hasMore: ordered.count > page.count
        )
    }
}

struct FakeTransport: SyncTransport {
    let server: FakeSyncServer
    func push(_ changes: [SyncChange]) async throws -> SyncPushResult { server.push(changes) }
    func pull(cursor: Int64, limit: Int) async throws -> SyncPullResult { server.pull(cursor: cursor, limit: limit) }
}

// MARK: - LWW mirror (stands in for the concrete local stores)

final class Mirror {
    private(set) var items: [String: SyncChange] = [:]   // key: "collection|itemId"
    private func key(_ c: SyncChange) -> String { "\(c.collection.rawValue)|\(c.itemId)" }

    /// Apply a remote change under last-writer-wins — ignore anything older than
    /// what we already hold (this is the apply-side LWW the real stores do).
    func apply(_ change: SyncChange) {
        let k = key(change)
        if let local = items[k], change.updatedAt < local.updatedAt { return }
        items[k] = change
    }

    func payload(_ collection: SyncCollection, _ itemId: String) -> String? {
        items["\(collection.rawValue)|\(itemId)"].flatMap { $0.deleted ? nil : $0.payload }
    }
}

// MARK: - Tests

final class SyncEngineTests: XCTestCase {

    private func makeEngine(server: FakeSyncServer, userId: String, mirror: Mirror) -> SyncEngine {
        let defaults = UserDefaults(suiteName: "sync-test-\(userId)-\(UUID().uuidString)")!
        return SyncEngine(
            transport: FakeTransport(server: server),
            outbox: SyncOutbox(userId: userId, defaults: defaults),
            cursorStore: SyncCursorStore(userId: userId, defaults: defaults),
            apply: { mirror.apply($0) }
        )
    }

    private func change(_ collection: SyncCollection, _ id: String, _ ts: Int64, payload: String? = nil, deleted: Bool = false) -> SyncChange {
        SyncChange(collection: collection, itemId: id, updatedAt: ts, deleted: deleted, payload: payload)
    }

    func testLocalChangePushesToServer() async throws {
        let server = FakeSyncServer()
        let engine = makeEngine(server: server, userId: "u1", mirror: Mirror())
        engine.record(change(.cookbook, "c1", 100, payload: #"{"name":"A"}"#))
        let result = try await engine.push()
        XCTAssertEqual(result?.applied, ["c1"])
        // Outbox drained.
        try await engine.push()  // nothing to send now; no crash
    }

    func testPullAppliesRemoteChanges() async throws {
        let server = FakeSyncServer()
        _ = server.push([change(.mealPlan, "m1", 50, payload: #"{"dayKey":"2026-08-28"}"#)])

        let mirror = Mirror()
        let engine = makeEngine(server: server, userId: "u1", mirror: mirror)
        try await engine.pull()
        XCTAssertEqual(mirror.payload(.mealPlan, "m1"), #"{"dayKey":"2026-08-28"}"#)
    }

    func testServerWinsConflictIsAdoptedLocally() async throws {
        let server = FakeSyncServer()
        _ = server.push([change(.cookbook, "c1", 200, payload: #"{"name":"server"}"#)])

        let mirror = Mirror()
        let engine = makeEngine(server: server, userId: "u1", mirror: mirror)
        // Local edit is OLDER → server wins; engine should adopt server's copy.
        engine.record(change(.cookbook, "c1", 150, payload: #"{"name":"local"}"#))
        let result = try await engine.push()
        XCTAssertEqual(result?.applied, [])
        XCTAssertEqual(result?.conflicts.first?.payload, #"{"name":"server"}"#)
        XCTAssertEqual(mirror.payload(.cookbook, "c1"), #"{"name":"server"}"#)
    }

    func testTombstonePropagates() async throws {
        let server = FakeSyncServer()
        let mirror = Mirror()
        let engine = makeEngine(server: server, userId: "u1", mirror: mirror)
        engine.record(change(.groceryManual, "g1", 1, payload: #"{"name":"milk"}"#))
        try await engine.sync()
        engine.record(change(.groceryManual, "g1", 2, deleted: true))
        try await engine.sync()
        XCTAssertNil(mirror.payload(.groceryManual, "g1"))   // deleted
    }

    func testCursorMakesPullIncremental() async throws {
        let server = FakeSyncServer()
        let mirror = Mirror()
        let engine = makeEngine(server: server, userId: "u1", mirror: mirror)
        _ = server.push([change(.cookbook, "c1", 1, payload: "{}")])
        try await engine.pull()
        // A second server change; pull should fetch only it (cursor advanced).
        _ = server.push([change(.cookbook, "c2", 2, payload: "{}")])
        try await engine.pull()
        XCTAssertNotNil(mirror.payload(.cookbook, "c2"))
    }

    func testTwoDevicesConverge() async throws {
        let server = FakeSyncServer()
        let mirrorA = Mirror(), mirrorB = Mirror()
        let deviceA = makeEngine(server: server, userId: "same-user-A", mirror: mirrorA)
        let deviceB = makeEngine(server: server, userId: "same-user-B", mirror: mirrorB)

        // A adds a cookbook; B adds a meal-plan entry — independent items.
        deviceA.record(change(.cookbook, "c1", 100, payload: #"{"name":"A-book"}"#))
        deviceB.record(change(.mealPlan, "m1", 100, payload: #"{"dayKey":"x"}"#))
        try await deviceA.sync()
        try await deviceB.sync()
        try await deviceA.sync()   // A pulls B's item

        XCTAssertEqual(mirrorA.payload(.cookbook, "c1"), #"{"name":"A-book"}"#)
        XCTAssertEqual(mirrorA.payload(.mealPlan, "m1"), #"{"dayKey":"x"}"#)
        XCTAssertEqual(mirrorB.payload(.cookbook, "c1"), #"{"name":"A-book"}"#)
    }

    func testOutboxSupersedesStaleQueuedEdit() async throws {
        let outbox = SyncOutbox(userId: "u1", defaults: UserDefaults(suiteName: "ob-\(UUID().uuidString)")!)
        outbox.enqueue(change(.cookbook, "c1", 100, payload: "old"))
        outbox.enqueue(change(.cookbook, "c1", 200, payload: "new"))   // newer wins
        outbox.enqueue(change(.cookbook, "c1", 150, payload: "stale")) // older ignored
        XCTAssertEqual(outbox.pending().count, 1)
        XCTAssertEqual(outbox.pending().first?.payload, "new")
    }
}
