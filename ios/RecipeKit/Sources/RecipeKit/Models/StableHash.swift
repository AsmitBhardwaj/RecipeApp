//
//  StableHash.swift
//  RecipeKit
//
//  A deterministic string hash for picking a stable bucket from an identifier.
//
//  Swift's built-in `Hasher` / `String.hashValue` is seeded randomly per process
//  launch, so it yields a DIFFERENT value each run — unusable for "always show
//  the same thing for this id." This FNV-1a implementation is fixed, so the same
//  seed maps to the same bucket across launches, devices, and OS versions.
//

import Foundation

/// Deterministically maps `seed` to an index in `0..<count` (FNV-1a, 64-bit).
/// Stable across processes — the same seed always returns the same index.
/// `count` must be > 0.
public func stableIndex(for seed: String, modulo count: Int) -> Int {
    precondition(count > 0, "count must be positive")
    var hash: UInt64 = 1469598103934665603  // FNV offset basis
    for byte in seed.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211        // FNV prime (wrapping multiply)
    }
    return Int(hash % UInt64(count))
}
