import Foundation

/// The server's view of the account's Pro entitlement, returned by
/// `/v1/entitlements/verify` and `/v1/entitlements/me`. The server is the
/// authority for API access; the client uses this to confirm a verified
/// subscription reached the backend.
public struct ServerEntitlementStatus: Decodable, Equatable, Sendable {
    public let isPro: Bool
    public let productId: String?
    public let proExpiresAt: String?
    public let graceExpiresAt: String?
    public let environment: String?

    enum CodingKeys: String, CodingKey {
        case isPro = "is_pro"
        case productId = "product_id"
        case proExpiresAt = "pro_expires_at"
        case graceExpiresAt = "grace_expires_at"
        case environment
    }
}

/// Posts a StoreKit 2 signed transaction (JWS) to the backend, which verifies it
/// against Apple and persists the account's Pro entitlement. Mirrors the auth /
/// app-key header conventions of the other RecipeKit clients and is URLProtocol-
/// testable (inject a `session` + `accessTokenProvider`).
public struct EntitlementClient {
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

    private struct VerifyBody: Encodable {
        let signed_transaction: String
        let transfer: Bool
    }

    /// Verify one signed transaction and return the resulting server entitlement.
    ///
    /// - `transfer`: pass `true` ONLY for an explicit "Restore Purchases" tap, which
    ///   lets the server move the subscription to this account (newest-wins).
    ///   Automatic launch / sign-in / `Transaction.updates` sync passes `false`
    ///   (refresh only — never claim another account's subscription).
    public func verify(signedTransaction: String, transfer: Bool = false) async throws -> ServerEntitlementStatus {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/entitlements/verify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = appKey()
        if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-App-Key") }
        request.setValue("Bearer \(try await accessTokenProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            VerifyBody(signed_transaction: signedTransaction, transfer: transfer)
        )
        return try await send(request)
    }

    /// The signed-in account's current server entitlement (no Apple round-trip;
    /// reads the stored entitlement). Used to gate the UI on the account, not the
    /// device's Apple ID.
    public func me() async throws -> ServerEntitlementStatus {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/entitlements/me"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = appKey()
        if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-App-Key") }
        request.setValue("Bearer \(try await accessTokenProvider())", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> ServerEntitlementStatus {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RecipeProviderError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RecipeProviderError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(ServerEntitlementStatus.self, from: data)
    }
}
