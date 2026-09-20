//
//  PaywallModel.swift
//  RecipeApp
//
//  View-model behind PaywallView. Holds the offering + selection + purchase
//  state and drives all copy off RecipeKit's PaywallCopy/PaywallPricing, so the
//  View is presentation-only. Depends only on the `EntitlementProviding` /
//  `PaywallPurchasing` protocols — never on RevenueCat (see docs/PAYWALL_WIRING).
//

import Foundation
import RecipeKit

@MainActor
final class PaywallModel: ObservableObject {

    enum LoadState: Equatable { case loading, loaded, failed }

    let trigger: PaywallTrigger
    private let entitlements: any EntitlementProviding
    private let purchasing: any PaywallPurchasing

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var offering: PaywallOffering?
    @Published var selectedPeriod: PaywallPeriod = .annual      // Annual pre-selected
    @Published private(set) var isPurchasing = false
    @Published var errorMessage: String?
    @Published var restoreMessage: String?
    /// Flips true once the sheet should dismiss (purchase or restore succeeded).
    @Published private(set) var didFinish = false

    init(
        trigger: PaywallTrigger,
        entitlements: any EntitlementProviding,
        purchasing: any PaywallPurchasing,
        initialPeriod: PaywallPeriod = .annual
    ) {
        self.trigger = trigger
        self.entitlements = entitlements
        self.purchasing = purchasing
        self.selectedPeriod = initialPeriod
    }

    // MARK: Copy (all from RecipeKit, never hardcoded)

    var headline: String { PaywallCopy.headline(for: trigger) }
    var subhead: String { PaywallCopy.subhead(for: trigger, freeImportLimit: entitlements.freeImportLimit) }
    var benefits: [String] { PaywallCopy.benefits(for: trigger) }

    var ctaTitle: String {
        offering.map { PaywallCopy.ctaTitle(selectedPeriod: selectedPeriod, offering: $0) } ?? " "
    }
    var finePrint: String {
        offering.map { PaywallCopy.finePrint(selectedPeriod: selectedPeriod, offering: $0) } ?? ""
    }
    var annualCardSubtitle: String { offering.map(PaywallCopy.annualCardSubtitle) ?? "" }
    var savingsPercent: Int? {
        offering.flatMap { PaywallPricing.savingsPercent(annualPrice: $0.annual.price, monthlyPrice: $0.monthly.price) }
    }

    // MARK: Actions

    func load() async {
        loadState = .loading
        do {
            offering = try await purchasing.loadOffering()
            loadState = .loaded
        } catch {
            loadState = .failed
        }
    }

    func select(_ period: PaywallPeriod) { selectedPeriod = period }

    func purchase() async {
        guard let offering else { return }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }
        do {
            switch try await purchasing.purchase(offering.plan(for: selectedPeriod)) {
            case .success:
                await entitlements.refresh()
                didFinish = true
            case .cancelled:
                break   // user cancelled — silent, stay on the sheet
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func restore() async {
        errorMessage = nil
        restoreMessage = nil
        do {
            switch try await purchasing.restore() {
            case .restored:
                await entitlements.refresh()
                restoreMessage = "Purchases restored."
                try? await Task.sleep(nanoseconds: 800_000_000)   // brief confirmation
                didFinish = true
            case .nothingToRestore:
                restoreMessage = "No active subscription found."
            }
        } catch {
            errorMessage = "Couldn't restore purchases. Please try again."
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? PaywallError {
        case .purchaseFailed(let m): return m
        case .loadFailed: return "Couldn't load subscription options. Please try again."
        case .restoreFailed(let m): return m
        case .none: return "Something went wrong. Please try again."
        }
    }
}
