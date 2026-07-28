// swift-tools-version: 5.9
import PackageDescription

// RecipeKit — code shared between the main app and the (future) Share Extension:
// the backend-mirroring data models and anonymous-identity/Keychain logic. Kept
// as a local package so both targets compile the exact same source, never a copy.
//
// Networking (the real API client) is intentionally NOT here yet — this pass is
// scoped to identity + one source of truth for the models.
let package = Package(
    name: "RecipeKit",
    // iOS 17 is the app's target. macOS 13 is declared only so the package's
    // unit tests can run on the host toolchain (`swift test`) — the async
    // URLSession / Duration APIs need macOS 13+.
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "RecipeKit", targets: ["RecipeKit"]),
    ],
    targets: [
        .target(name: "RecipeKit"),
        .testTarget(name: "RecipeKitTests", dependencies: ["RecipeKit"]),
    ]
)
