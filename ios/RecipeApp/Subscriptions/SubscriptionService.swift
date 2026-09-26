//
//  SubscriptionService.swift
//  RecipeApp
//
//  App-wide StoreKit 2 product, purchase, and restore coordinator.
//
//  Pro access is gated on the SERVER entitlement for the SIGNED-IN account
//  (`/v1/entitlements/*`), never on device-local StoreKit alone. Device StoreKit
//  (`Transaction.currentEntitlements`) is Apple-ID-scoped and identical for every
//  Platter account on a device, so it is used ONLY to (a) obtain a signed
//  transaction to refresh the matching account and (b) detect the paywall
//  "already subscribed on this Apple ID, different account" case. It never unlocks
//  Pro by itself.
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
        case activating
        case pending
        case cancelled
        case succeeded
        case unverified
        case failed(String)

        var message: String? {
            switch self {
            case .activating:
                return "Activating Pro…"
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
    @Published private(set) var introOfferEligibility: [String: Bool] = [:]
    /// Device StoreKit entitlement (Apple-ID-scoped). NOT the Pro gate — see file
    /// header. Used only for the paywall "already subscribed" detection.
    @Published private(set) var entitlementState: ProEntitlementState = .unknown
    /// The server-verified entitlement for the SIGNED-IN account. This is the Pro
    /// gate. Starts false; set only from a server response for the current account.
    @Published private(set) var serverIsPro: Bool = false
    /// True once a server entitlement response has resolved for the current account
    /// (so the app-open paywall only decides after resolution — no flash for Pro).
    /// Reset on account change. Stays false when offline / the check fails.
    @Published private(set) var serverEntitlementResolved: Bool = false
    /// Set once the onboarding paywall has been presented this app session, so the
    /// periodic app-open paywall is not also shown in the same session.
    @Published private(set) var onboardingPaywallShownThisSession: Bool = false
    @Published private(set) var purchaseState: PurchaseState = .idle
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isRefreshingEntitlement = false
    @Published private(set) var productLoadError: String?
    @Published private(set) var managementError: String?

    private static let cachedStatusKey = "platterPro.cachedStatus.v1"
    private let defaults: UserDefaults
    private var updatesTask: Task<Void, Never>?
    private var hasStarted = false

    /// The signed-in account's id as a UUID, stamped onto a purchase as
    /// `appAccountToken` so the backend binds the subscription to this account.
    private let accountUUID: () -> UUID?
    /// The signed-in account's id string, used to key the per-account no-flash cache.
    private let accountID: () -> String?
    /// Posts a signed transaction to `/v1/entitlements/verify` and returns the
    /// server's entitlement for the signed-in account. `transfer` is true only for
    /// an explicit Restore. Returns nil on network/auth failure. Injectable for tests.
    private let syncTransaction: (_ jws: String, _ transfer: Bool) async -> ServerEntitlementStatus?
    /// Fetches `/v1/entitlements/me` for the signed-in account. Returns nil on
    /// failure. Injectable for tests.
    private let fetchEntitlement: () async -> ServerEntitlementStatus?

    enum EntitlementSyncError: Error { case notSignedIn }

    init(
        defaults: UserDefaults = .standard,
        accountUUID: @escaping () -> UUID? = { nil },
        accountID: @escaping () -> String? = { nil },
        syncTransaction: ((_ jws: String, _ transfer: Bool) async -> ServerEntitlementStatus?)? = nil,
        fetchEntitlement: (() async -> ServerEntitlementStatus?)? = nil
    ) {
        self.defaults = defaults
        self.accountUUID = accountUUID
        self.accountID = accountID
        self.syncTransaction = syncTransaction ?? Self.makeSync()
        self.fetchEntitlement = fetchEntitlement ?? Self.makeFetch()
    }

    private static func makeClient() -> EntitlementClient {
        EntitlementClient(accessTokenProvider: {
            guard let token = await SessionTokenProvider().accessTokenOrNil() else {
                throw EntitlementSyncError.notSignedIn
            }
            return token
        })
    }

    private static func makeSync() -> (String, Bool) async -> ServerEntitlementStatus? {
        return { jws, transfer in
            do { return try await makeClient().verify(signedTransaction: jws, transfer: transfer) }
            catch {
                storeLog.error("entitlement verify failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    private static func makeFetch() -> () async -> ServerEntitlementStatus? {
        return {
            do { return try await makeClient().me() }
            catch {
                storeLog.error("entitlement fetch failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Starts exactly one transaction listener, then loads products and refreshes
    /// the account's server entitlement. Safe to call from multiple screens.
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
        introOfferEligibility = [:]

        let requested = SubscriptionConfiguration.productIDs
        storeLog.log("Requesting StoreKit products: \(requested.sorted().joined(separator: ", "), privacy: .public)")
        do {
            let loaded = try await Product.products(for: requested)
            storeLog.log("StoreKit returned \(loaded.count, privacy: .public) product(s): \(loaded.map(\.id).sorted().joined(separator: ", "), privacy: .public)")
            let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            products = SubscriptionConfiguration.orderedProductIDs.compactMap { byID[$0] }
            var eligibility: [String: Bool] = [:]
            for product in products {
                guard let subscription = product.subscription,
                      subscription.introductoryOffer != nil else {
                    eligibility[product.id] = false
                    continue
                }
                eligibility[product.id] = await subscription.isEligibleForIntroOffer
            }
            introOfferEligibility = eligibility

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
            introOfferEligibility = [:]
        }

        isLoadingProducts = false
        await refreshEntitlement()
    }

    /// Refreshes the signed-in account's server entitlement. Reads device StoreKit
    /// only to (a) refresh the matching account (transfer=false — never claims
    /// another account's subscription) and (b) populate `entitlementState` for the
    /// paywall. Falls back to `/v1/entitlements/me` for the account's truth.
    func refreshEntitlement() async {
        isRefreshingEntitlement = true
        let jws = await readDeviceEntitlement()

        var status: ServerEntitlementStatus?
        if let jws {
            // Automatic sync: refresh only. The server grants only if this account
            // owns the subscription (or appAccountToken matches); it will NOT move a
            // subscription owned by another account.
            status = await syncTransaction(jws, false)
        }
        if status == nil {
            status = await fetchEntitlement()
        }
        applyServerStatus(status)
        isRefreshingEntitlement = false
    }

    func purchase(_ product: Product) async {
        guard SubscriptionConfiguration.productIDs.contains(product.id) else {
            purchaseState = .failed("This subscription plan isn't configured for Platter Pro.")
            return
        }

        purchaseState = .purchasing
        do {
            // Stamp the account UUID as appAccountToken so the backend binds this
            // subscription to the signed-in account (one subscription → one account).
            let purchaseOptions: Set<Product.PurchaseOption>
            if let token = accountUUID() {
                purchaseOptions = [.appAccountToken(token)]
            } else {
                purchaseOptions = []
            }
            switch try await product.purchase(options: purchaseOptions) {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    // Wait for the server to confirm Pro FOR THIS ACCOUNT before
                    // showing Pro — the purchase carries appAccountToken, so the
                    // server grants this account.
                    purchaseState = .activating
                    _ = await readDeviceEntitlement()
                    // A fresh purchase carries this account's appAccountToken and
                    // activates on transfer=false. If it doesn't, StoreKit returned an
                    // ALREADY-OWNED subscription bound to another Platter account (the
                    // "You're currently subscribed to this" case). Don't dead-end:
                    // treat it as an explicit restore to THIS account — the user just
                    // tapped to get Pro here, and the Apple-signed JWS proves Apple-ID
                    // ownership. This is the transfer=true (newest-wins) path.
                    var status = await syncTransaction(verification.jwsRepresentation, false)
                    applyServerStatus(status)
                    if !serverIsPro {
                        let restored = await syncTransaction(verification.jwsRepresentation, true)
                        if restored != nil { status = restored }
                        applyServerStatus(restored)
                    }
                    if serverIsPro {
                        purchaseState = .succeeded
                    } else if status == nil {
                        purchaseState = .failed("We couldn't reach the server to activate Pro. Please try again.")
                    } else {
                        purchaseState = .failed("The purchase completed, but Pro wasn't activated for this account. Please try again.")
                    }
                case .unverified:
                    purchaseState = .unverified
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

    /// Explicit "Restore Purchases": may MOVE the subscription to this account
    /// (transfer=true, newest-wins) — the only path that transfers.
    func restorePurchases() async {
        purchaseState = .purchasing
        do {
            try await AppStore.sync()
            let jws = await readDeviceEntitlement()
            if let jws {
                applyServerStatus(await syncTransaction(jws, true))
            } else {
                applyServerStatus(await fetchEntitlement())
            }
            purchaseState = serverIsPro
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
        if purchaseState != .purchasing && purchaseState != .activating { purchaseState = .idle }
    }

    func clearManagementError() {
        managementError = nil
    }

    #if DEBUG
    /// Screenshot/preview harness only: force the account's server-Pro state so the
    /// free/Pro variants can be captured without signing in or hitting the backend.
    func _debugSetServerPro(_ value: Bool) { serverIsPro = value }
    #endif

    /// Clears this device's cached Pro signals for ALL accounts on sign-out /
    /// account deletion, and resets server Pro to false. Deliberately does NOT
    /// re-read device StoreKit — a new sign-in must start FREE until the server
    /// confirms Pro for that specific account (device Apple-ID subscriptions do not
    /// leak Pro across Platter accounts).
    func resetForAccountChange() async {
        entitlementState = .unknown
        serverIsPro = false
        serverEntitlementResolved = false
        purchaseState = .idle
        defaults.removeObject(forKey: Self.cachedStatusKey)
        ProEntitlementCache.clear()
    }

    /// True while a purchase or restore is mid-flight — the app-open paywall must
    /// not appear over it.
    var purchaseInProgress: Bool {
        purchaseState == .purchasing || purchaseState == .activating
    }

    /// Called when the onboarding paywall is presented, so the periodic app-open
    /// paywall is suppressed for the rest of this session.
    func markOnboardingPaywallShown() {
        onboardingPaywallShownThisSession = true
    }

    /// Whether Pro-gated UI should be UNLOCKED for the signed-in account: the
    /// server entitlement, or the per-account cached server answer (no-flash on
    /// cold launch / offline). Device StoreKit alone never unlocks this.
    var isProUnlocked: Bool {
        ProGate.isUnlocked(serverIsPro: serverIsPro, cached: ProEntitlementCache.isEntitled(accountId: accountID()))
    }

    /// Account-scoped Pro (same as `isProUnlocked`). Kept for call sites that read
    /// "does this account have Pro".
    var hasProAccess: Bool { isProUnlocked }

    /// The device's Apple ID owns an active Platter Pro subscription (from device
    /// StoreKit). Used only by the paywall.
    var deviceHasEntitlement: Bool { entitlementState.grantsAccess }

    /// Paywall edge case: the device's Apple ID already has Platter Pro but the
    /// signed-in account is not entitled — offer Restore, not Subscribe.
    var needsRestore: Bool {
        ProGate.needsRestore(deviceHasEntitlement: deviceHasEntitlement, serverIsPro: serverIsPro)
    }

    var settingsStatusText: String {
        if serverIsPro { return "Active" }
        if isRefreshingEntitlement {
            return defaults.string(forKey: Self.cachedStatusKey) ?? "Checking…"
        }
        return "Upgrade"
    }

    // MARK: - Private

    private func applyServerStatus(_ status: ServerEntitlementStatus?) {
        // Offline / no signal: leave serverIsPro and the cache untouched so a
        // returning subscriber keeps Pro via the per-account cache (no flash) and a
        // free account stays free.
        guard let status else { return }
        serverIsPro = status.isPro
        serverEntitlementResolved = true
        ProEntitlementCache.set(status.isPro, accountId: accountID())
        defaults.set(status.isPro ? "Active" : "Upgrade", forKey: Self.cachedStatusKey)
    }

    /// Reads device StoreKit into `entitlementState` (for the paywall) and returns a
    /// verified current transaction's JWS, if any.
    @discardableResult
    private func readDeviceEntitlement() async -> String? {
        var currentRecords: [SubscriptionEntitlementRecord] = []
        var currentVerifiedJWS: String?
        for await result in Transaction.currentEntitlements {
            guard SubscriptionConfiguration.productIDs.contains(result.unsafePayloadValue.productID) else {
                continue
            }
            currentRecords.append(record(from: result))
            if case .verified = result {
                currentVerifiedJWS = result.jwsRepresentation
            }
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
        return currentVerifiedJWS
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
                // Refresh only (transfer=false) — a renewal must not move the
                // subscription to whatever account happens to be signed in.
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
