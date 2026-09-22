//
//  SubscriptionService.swift
//  RecipeApp
//
//  App-wide StoreKit 2 product, purchase, restore, and entitlement coordinator.
//  Verified StoreKit transactions are the sole source of Pro access.
//

import Foundation
import os
import RecipeKit
import StoreKit
import UIKit

/// Diagnostic log for StoreKit product loading. Filter in Console / `log stream`
/// with: subsystem == "com.recipeapp" category == "StoreKit".
private let storeLog = Logger(subsystem: "com.recipeapp", category: "StoreKit")

@MainActor
final class SubscriptionService: ObservableObject {
    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case pending
        case cancelled
        case succeeded
        case unverified
        case failed(String)

        var message: String? {
            switch self {
            case .pending:
                return "Your purchase is waiting for approval. Pro will activate after Apple confirms it."
            case .cancelled:
                return "Purchase cancelled."
            case .unverified:
                return "Apple couldn't verify this transaction. No Pro access was granted."
            case .failed(let message):
                return message
            default:
                return nil
            }
        }
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlementState: ProEntitlementState = .unknown
    @Published private(set) var purchaseState: PurchaseState = .idle
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isRefreshingEntitlement = false
    @Published private(set) var productLoadError: String?
    @Published private(set) var managementError: String?

    private static let cachedStatusKey = "platterPro.cachedStatus.v1"
    private let defaults: UserDefaults
    private var updatesTask: Task<Void, Never>?
    private var hasStarted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Starts exactly one transaction listener, then loads products and refreshes
    /// verified entitlement state. Safe to call from multiple screens.
    func start() async {
        guard !hasStarted else {
            await refreshEntitlement()
            return
        }
        hasStarted = true
        listenForTransactions()
        await reloadProductsAndEntitlement()
    }

    func reloadProductsAndEntitlement() async {
        isLoadingProducts = true
        productLoadError = nil

        let requested = SubscriptionConfiguration.productIDs
        storeLog.log("Requesting StoreKit products: \(requested.sorted().joined(separator: ", "), privacy: .public)")
        do {
            let loaded = try await Product.products(for: requested)
            storeLog.log("StoreKit returned \(loaded.count, privacy: .public) product(s): \(loaded.map(\.id).sorted().joined(separator: ", "), privacy: .public)")
            let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            products = SubscriptionConfiguration.orderedProductIDs.compactMap { byID[$0] }

            if products.isEmpty {
                // Empty here almost always means no StoreKit configuration is
                // active (scheme's StoreKit config not wired, or products/paid-app
                // agreement missing in App Store Connect) — the IDs themselves are
                // validated against PlatterPro.storekit in the test suite.
                storeLog.error("No matching products for requested IDs — plans will show as unavailable.")
                productLoadError = "Platter Pro plans are unavailable right now. Please try again later."
            }
        } catch {
            storeLog.error("Product.products(for:) threw: \(String(describing: error), privacy: .public)")
            productLoadError = Self.userMessage(for: error, fallback: "Couldn't load Platter Pro plans.")
        }

        isLoadingProducts = false
        await refreshEntitlement()
    }

    func refreshEntitlement() async {
        isRefreshingEntitlement = true

        var currentRecords: [SubscriptionEntitlementRecord] = []
        for await result in Transaction.currentEntitlements {
            guard SubscriptionConfiguration.productIDs.contains(result.unsafePayloadValue.productID) else {
                continue
            }
            currentRecords.append(record(from: result))
        }

        var latestRecords: [SubscriptionEntitlementRecord] = []
        for productID in SubscriptionConfiguration.productIDs {
            if let result = await Transaction.latest(for: productID) {
                latestRecords.append(record(from: result))
            }
        }

        entitlementState = ProEntitlementEvaluator.evaluate(
            current: currentRecords,
            latest: latestRecords,
            productIDs: SubscriptionConfiguration.productIDs
        )
        cacheDisplayState()
        // Mirror the verified Pro status into the App Group so the Share Extension
        // (which can't query StoreKit) can send the X-Pro-Entitled claim that
        // waives the server-side free-import limit. Derived from verified state,
        // never from cached UI text.
        ProEntitlementCache.set(entitlementState.grantsAccess)
        isRefreshingEntitlement = false
    }

    func purchase(_ product: Product) async {
        guard SubscriptionConfiguration.productIDs.contains(product.id) else {
            purchaseState = .failed("This subscription plan isn't configured for Platter Pro.")
            return
        }

        purchaseState = .purchasing
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlement()
                    purchaseState = entitlementState.grantsAccess
                        ? .succeeded
                        : .failed("The purchase completed, but an active entitlement wasn't found yet. Please try Restore Purchases.")
                case .unverified:
                    purchaseState = .unverified
                    await refreshEntitlement()
                }
            case .pending:
                purchaseState = .pending
            case .userCancelled:
                purchaseState = .cancelled
            @unknown default:
                purchaseState = .failed("The App Store returned an unknown purchase result.")
            }
        } catch {
            purchaseState = .failed(Self.userMessage(for: error, fallback: "The purchase couldn't be completed."))
        }
    }

    func restorePurchases() async {
        purchaseState = .purchasing
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            purchaseState = entitlementState.grantsAccess
                ? .succeeded
                : .failed("No active Platter Pro subscription was found for this Apple Account.")
        } catch {
            purchaseState = .failed(Self.userMessage(for: error, fallback: "Purchases couldn't be restored."))
        }
    }

    func showSubscriptionManagement() async {
        managementError = nil
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            managementError = "Subscription management isn't available right now."
            return
        }

        do {
            try await AppStore.showManageSubscriptions(in: scene)
            await refreshEntitlement()
        } catch {
            managementError = Self.userMessage(for: error, fallback: "Couldn't open subscription management.")
        }
    }

    func clearPurchaseMessage() {
        if purchaseState != .purchasing { purchaseState = .idle }
    }

    func clearManagementError() {
        managementError = nil
    }

    /// Reusable gate for future Pro-only features. This never consults cached UI
    /// state, a button tap, or an account field.
    var hasProAccess: Bool {
        entitlementState.grantsAccess
    }

    /// Whether Pro-gated UI should be UNLOCKED. Combines the verified live grant
    /// with the App-Group–cached entitlement (`ProGate.isUnlocked`) so a returning
    /// subscriber sees Pro content with NO flash of a locked state while the
    /// StoreKit refresh is still resolving on cold launch. Presentation gate only
    /// — not a security/cost boundary. Reads `hasProAccess` (an @Published-derived
    /// value), so SwiftUI views observing this service re-render when a purchase
    /// completes in-session.
    var isProUnlocked: Bool {
        ProGate.isUnlocked(live: hasProAccess, cached: ProEntitlementCache.isEntitled)
    }

    var settingsStatusText: String {
        if entitlementState.grantsAccess { return "Active" }
        if isRefreshingEntitlement || entitlementState == .unknown {
            return defaults.string(forKey: Self.cachedStatusKey) ?? "Checking…"
        }
        return "Upgrade"
    }

    private func listenForTransactions() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }

                switch update {
                case .verified(let transaction):
                    if SubscriptionConfiguration.productIDs.contains(transaction.productID) {
                        await transaction.finish()
                    }
                case .unverified:
                    break
                }
                await self.refreshEntitlement()
            }
        }
    }

    private func record(
        from result: VerificationResult<Transaction>
    ) -> SubscriptionEntitlementRecord {
        switch result {
        case .verified(let transaction):
            return SubscriptionEntitlementRecord(
                productID: transaction.productID,
                isVerified: true,
                expirationDate: transaction.expirationDate,
                revocationDate: transaction.revocationDate
            )
        case .unverified(let transaction, _):
            return SubscriptionEntitlementRecord(
                productID: transaction.productID,
                isVerified: false,
                expirationDate: transaction.expirationDate,
                revocationDate: transaction.revocationDate
            )
        }
    }

    private func cacheDisplayState() {
        defaults.set(entitlementState.grantsAccess ? "Active" : "Upgrade", forKey: Self.cachedStatusKey)
    }

    private static func userMessage(for error: Error, fallback: String) -> String {
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .networkError:
                return "The App Store couldn't be reached. Check your connection and try again."
            case .userCancelled:
                return "Purchase cancelled."
            case .notAvailableInStorefront:
                return "Platter Pro isn't available in your storefront."
            default:
                break
            }
        }
        return error.localizedDescription.isEmpty ? fallback : error.localizedDescription
    }
}

private extension VerificationResult {
    var unsafePayloadValue: SignedType {
        switch self {
        case .verified(let value), .unverified(let value, _): return value
        }
    }
}
