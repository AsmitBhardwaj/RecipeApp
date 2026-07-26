//
//  RecipeApp.swift
//  RecipeApp
//
//  App entry point. Constructs the single `RecipeProvider` (mock today) and
//  hands it to the UI. This constructor call is the one place that changes
//  when the real backend is wired up: swap `MockRecipeProvider()` for an
//  `APIRecipeProvider(...)`.
//

import SwiftUI
import RecipeKit

@main
struct RecipeApp: App {
    /// The app-wide data source. Injected down into the views that need it.
    private let recipeProvider: RecipeProvider = MockRecipeProvider()

    init() {
        #if DEBUG
        // Temporary verification hook (removed after this session): run the
        // App Group Keychain identity self-check when launched with the flag.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-runIdentityCheck") {
            var report = ""
            if args.contains("-resetIdentity") {
                RecipeKitDiagnostics.resetForTesting()
                report += "[diagnostic] reset identity (cleared stored ID)\n\n"
            }
            let result = RecipeKitDiagnostics.identityReport()
            report += result.report
            print("\n\(report)\n")
            // Also write into the shared App Group container so the result can be
            // read back reliably from disk (also proves the container is usable).
            if let dir = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroup.identifier) {
                try? report.write(to: dir.appendingPathComponent("identity_report.txt"),
                                  atomically: true, encoding: .utf8)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(recipeProvider: recipeProvider)
        }
    }
}
