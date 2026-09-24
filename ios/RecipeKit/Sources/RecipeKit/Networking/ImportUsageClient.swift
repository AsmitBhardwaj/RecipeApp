import Foundation

public struct ImportUsage: Decodable, Equatable, Sendable {
    public let limit: Int
    public let used: Int
    public let remaining: Int
    public let resetsAt: Date
    public let isLimited: Bool

    enum CodingKeys: String, CodingKey {
        case limit, used, remaining
        case resetsAt = "resets_at"
        case isLimited = "is_limited"
    }
}

public struct ImportUsageClient {
    private let baseURL: URL
    private let session: URLSession
    private let appKey: () -> String
    private let accessTokenProvider: () async throws -> String

    public init(
        baseURL: URL = APIRecipeProvider.defaultBaseURL,
        session: URLSession = .shared,
        appKey: @escaping () -> String = { AppConfig.appKey },
        accessTokenProvider: @escaping () async throws -> String
    ) {
        self.baseURL = baseURL
        self.session = session
        self.appKey = appKey
        self.accessTokenProvider = accessTokenProvider
    }

    public func fetch() async throws -> ImportUsage {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/import-usage"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = appKey()
        if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-App-Key") }
        request.setValue("Bearer \(try await accessTokenProvider())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RecipeProviderError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RecipeProviderError.httpStatus(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ImportUsage.self, from: data)
    }
}
