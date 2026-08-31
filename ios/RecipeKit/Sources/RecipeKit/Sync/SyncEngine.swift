//
//  SyncEngine.swift
//  RecipeKit
//
//  Orchestrates the mirror + outbox model against the sync API:
//    record()  enqueue a local mutation (the caller also writes its own store)
//    push()    send the outbox; adopt any server-wins conflicts; clear resolved
//    pull()    apply every server change since the cursor into the local mirror
//    sync()    push then pull
//
//  The engine is transport-agnostic (SyncTransport) and store-agnostic: it hands
//  each remote change to an `apply` closure the app provides, which writes it
//  into the right local store. That closure is where last-writer-wins on APPLY
//  lives — it should ignore a remote change older than the local copy (Stage
//  2b-ii wires the concrete stores). The engine itself just moves records.
//
//  Not reentrant: callers serialize sync()/push()/pull() (the app drives it from
//  a single Task). `record()` is safe to call anytime.
//

import Foundation

/// The push/pull surface the engine needs. `SyncClient` conforms; tests provide
/// an in-memory fake.
public protocol SyncTransport: Sendable {
    func push(_ changes: [SyncChange]) async throws -> SyncPushResult
    func pull(cursor: Int64, limit: Int) async throws -> SyncPullResult
}

extension SyncClient: SyncTransport {}

public final class SyncEngine {
    private let transport: SyncTransport
    private let outbox: SyncOutbox
    private let cursorStore: SyncCursorStore
    private let apply: (SyncChange) -> Void
    private let pullLimit: Int

    public init(
        transport: SyncTransport,
        outbox: SyncOutbox,
        cursorStore: SyncCursorStore,
        pullLimit: Int = 500,
        apply: @escaping (SyncChange) -> Void
    ) {
        self.transport = transport
        self.outbox = outbox
        self.cursorStore = cursorStore
        self.apply = apply
        self.pullLimit = pullLimit
    }

    /// Queue a local mutation for the next push. The caller is responsible for
    /// writing its own local store; this only records the intent to sync.
    public func record(_ change: SyncChange) {
        outbox.enqueue(change)
    }

    /// Drain the outbox. Server-wins conflicts are applied locally (the client
    /// adopts the server's copy); resolved entries are cleared from the queue.
    @discardableResult
    public func push() async throws -> SyncPushResult? {
        let pending = outbox.pending()
        guard !pending.isEmpty else { return nil }
        let result = try await transport.push(pending)
        for conflict in result.conflicts {
            apply(conflict)
        }
        outbox.resolve(sent: pending)
        return result
    }

    /// Apply everything the server has that this account hasn't seen, advancing
    /// the cursor. Pages through `has_more`.
    public func pull() async throws {
        var cursor = cursorStore.cursor()
        while true {
            let result = try await transport.pull(cursor: cursor, limit: pullLimit)
            for change in result.changes {
                apply(change)
            }
            let advanced = result.cursor > cursor
            if advanced {
                cursor = result.cursor
                cursorStore.setCursor(cursor)
            }
            if !result.hasMore || result.changes.isEmpty { break }
        }
    }

    /// Full round-trip: push local changes, then pull remote ones.
    public func sync() async throws {
        try await push()
        try await pull()
    }
}
