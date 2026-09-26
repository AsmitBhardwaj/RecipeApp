import Foundation

public struct RecipeSourceAttribution: Equatable, Sendable {
    public let label: String
    public let url: URL
}

public extension Recipe {
    /// Review-safe external attribution. Only HTTP(S) URLs are tappable; malformed
    /// or non-web schemes are ignored instead of handed to the system.
    var sourceAttribution: RecipeSourceAttribution? {
        guard let sourceUrl,
              let url = URL(string: sourceUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }

        let platformName: String
        switch sourcePlatform?.lowercased() {
        case "instagram": platformName = "Instagram"
        case "tiktok": platformName = "TikTok"
        default: platformName = host.removingWWWPrefix
        }

        let creator = sourceCreator?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label: String
        if let creator, !creator.isEmpty {
            let displayedCreator: String
            if sourcePlatform == "instagram" || sourcePlatform == "tiktok" {
                displayedCreator = creator.hasPrefix("@") ? creator : "@\(creator)"
            } else {
                displayedCreator = creator
            }
            label = "Source: \(displayedCreator) on \(platformName)"
        } else {
            label = "Source: \(platformName)"
        }
        return RecipeSourceAttribution(label: label, url: url)
    }
}

private extension String {
    var removingWWWPrefix: String {
        hasPrefix("www.") ? String(dropFirst(4)) : self
    }
}
